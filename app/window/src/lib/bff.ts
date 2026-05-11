// Shared BFF helpers.
//
// Both /api/alerts and /api/alerts/[id] use these. Centralising the
// upstream-call logic means auth, error mapping, and observability live
// in one place and stay consistent as we add more endpoints.
//
// Design notes:
// - getIdToken reads the Cognito ID token from the *server-side* Amplify
//   context, which in turn reads the encrypted cookie set by the SDK
//   during sign-in. The browser never sees this token.
// - proxyToBrain forwards the token as a Bearer header to the Brain and
//   passes upstream status codes (401/404/etc.) through untouched.
// - Unreachable upstream returns 502; an unexpected upstream 5xx returns
//   a 502 with the Brain's status echoed in the details field.

import { cookies } from "next/headers"
import { fetchAuthSession } from "aws-amplify/auth/server"

import { runWithAmplifyServerContext } from "@/lib/amplify-server-utils"

import type { BffError } from "@/lib/types"

const BRAIN_BASE_URL = process.env.BRAIN_BASE_URL ?? ""

if (!BRAIN_BASE_URL) {
  // Fail fast on misconfiguration. This module is imported only by route
  // handlers so the error surfaces during the first request in a missing-
  // env-var environment instead of much later.
  console.warn(
    "[bff] BRAIN_BASE_URL is not set. " +
      "BFF requests to the Brain will fail until this is configured.",
  )
}

/** Result type for proxyToBrain. Either an ok response with parsed JSON
 * data, or an error envelope. Callers handle both shapes. */
export type BffResult<T> =
  | { ok: true; data: T; status: number }
  | { ok: false; error: BffError }

export async function getIdToken(): Promise<string | null> {
  return runWithAmplifyServerContext({
    nextServerContext: { cookies },
    operation: async (contextSpec) => {
      try {
        const session = await fetchAuthSession(contextSpec)
        const idToken = session.tokens?.idToken?.toString()
        return idToken ?? null
      } catch {
        return null
      }
    },
  })
}

export async function proxyToBrain<T>(
  path: string,
  init?: RequestInit,
): Promise<BffResult<T>> {
  // Defensive: if we are misconfigured, do not even try the fetch.
  if (!BRAIN_BASE_URL) {
    return {
      ok: false,
      error: {
        error: "internal_error",
        status: 500,
        details: "BRAIN_BASE_URL is not configured",
      },
    }
  }

  const idToken = await getIdToken()
  if (!idToken) {
    return {
      ok: false,
      error: {
        error: "unauthenticated",
        status: 401,
        details: "No id token available in session",
      },
    }
  }

  const url = `${BRAIN_BASE_URL}${path}`
  const headers = new Headers(init?.headers)
  headers.set("authorization", `Bearer ${idToken}`)
  headers.set("accept", "application/json")

  let response: Response
  try {
    response = await fetch(url, {
      ...init,
      headers,
      // BFF requests are user-scoped and time-sensitive; never cache here.
      // The browser does not control Brain freshness.
      cache: "no-store",
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return {
      ok: false,
      error: {
        error: "upstream_unreachable",
        status: 502,
        details: message,
      },
    }
  }

  if (response.ok) {
    try {
      const data = (await response.json()) as T
      return { ok: true, data, status: response.status }
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return {
        ok: false,
        error: {
          error: "upstream_error",
          status: 502,
          details: `Brain returned non-JSON body: ${message}`,
        },
      }
    }
  }

  // Non-2xx from Brain. Map common cases to clean envelopes; pass through
  // everything else as upstream_error with the Brain status preserved in
  // the details field so a developer can diagnose without reading logs.
  let upstreamBody: unknown = undefined
  try {
    upstreamBody = await response.json()
  } catch {
    // Brain returned a non-JSON error body. Not fatal; just don't include
    // it in the response.
  }

  const upstreamDetail =
    upstreamBody && typeof upstreamBody === "object" && "detail" in upstreamBody
      ? String((upstreamBody as { detail: unknown }).detail)
      : undefined

  if (response.status === 401) {
    return {
      ok: false,
      error: {
        error: "upstream_unauthorized",
        status: 401,
        details: upstreamDetail,
      },
    }
  }

  if (response.status === 404) {
    return {
      ok: false,
      error: {
        error: "not_found",
        status: 404,
        details: upstreamDetail,
      },
    }
  }

  return {
    ok: false,
    error: {
      error: "upstream_error",
      status: 502,
      details: `Brain returned ${response.status}${upstreamDetail ? `: ${upstreamDetail}` : ""}`,
    },
  }
}
