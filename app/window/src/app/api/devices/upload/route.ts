// BFF: POST /api/devices/upload
// Accepts a CSV body from the browser, forwards it to the Brain with
// the Cognito ID token attached. Returns the Brain's 202 Accepted with
// {job_id, status: "queued"} on success.
//
// The Brain enforces a 1MB hard cap. We mirror it client-side in the
// upload-flow component for a better UX (fail-fast before the upload).
//
// Why we keep this thin: the Brain owns validation, tenant scoping,
// payload limits, and job creation. The BFF's only job is to attach
// the JWT so the browser never sees the token.

import { NextRequest, NextResponse } from "next/server"

import { getIdToken } from "@/lib/bff"
import type { DeviceUploadJobCreateResponse } from "@/lib/types"

export const dynamic = "force-dynamic"
export const revalidate = 0

const BRAIN_BASE_URL = process.env.BRAIN_BASE_URL ?? ""

export async function POST(req: NextRequest) {
  if (!BRAIN_BASE_URL) {
    return NextResponse.json(
      {
        error: "internal_error",
        status: 500,
        details: "BRAIN_BASE_URL is not configured",
      },
      { status: 500 },
    )
  }

  const idToken = await getIdToken()
  if (!idToken) {
    return NextResponse.json(
      {
        error: "unauthenticated",
        status: 401,
        details: "No id token available in session",
      },
      { status: 401 },
    )
  }

  // Forward the raw CSV body. Don't try to parse or validate it here -
  // the Brain has the canonical validator (MDALL_COLUMN_MAP, required-
  // field checks, device_class enum check). Doubling validation in two
  // places means two places where it can drift.
  const body = await req.text()

  const filename = req.headers.get("x-upload-filename") ?? ""

  const headers: Record<string, string> = {
    authorization: `Bearer ${idToken}`,
    "content-type": "text/csv",
    accept: "application/json",
  }
  if (filename) {
    headers["x-upload-filename"] = filename
  }

  let response: Response
  try {
    response = await fetch(`${BRAIN_BASE_URL}/devices/upload`, {
      method: "POST",
      headers,
      body,
      cache: "no-store",
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    return NextResponse.json(
      {
        error: "upstream_unreachable",
        status: 502,
        details: message,
      },
      { status: 502 },
    )
  }

  if (response.ok) {
    try {
      const data = (await response.json()) as DeviceUploadJobCreateResponse
      return NextResponse.json(data, { status: response.status })
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      return NextResponse.json(
        {
          error: "upstream_error",
          status: 502,
          details: `Brain returned non-JSON body: ${message}`,
        },
        { status: 502 },
      )
    }
  }

  // Non-2xx from Brain - pass through with normalised envelope so the
  // client gets a useful error message.
  let upstreamBody: unknown = undefined
  try {
    upstreamBody = await response.json()
  } catch {
    // Brain returned non-JSON error; not fatal
  }

  const upstreamDetail =
    upstreamBody && typeof upstreamBody === "object" && "detail" in upstreamBody
      ? String((upstreamBody as { detail: unknown }).detail)
      : undefined

  if (response.status === 401) {
    return NextResponse.json(
      { error: "upstream_unauthorized", status: 401, details: upstreamDetail },
      { status: 401 },
    )
  }
  if (response.status === 413) {
    return NextResponse.json(
      {
        error: "upstream_error",
        status: 413,
        details: upstreamDetail ?? "Upload exceeds maximum size of 1MB",
      },
      { status: 413 },
    )
  }
  if (response.status === 400) {
    return NextResponse.json(
      {
        error: "upstream_error",
        status: 400,
        details: upstreamDetail ?? "Invalid CSV payload",
      },
      { status: 400 },
    )
  }

  return NextResponse.json(
    {
      error: "upstream_error",
      status: 502,
      details: `Brain returned ${response.status}${upstreamDetail ? `: ${upstreamDetail}` : ""}`,
    },
    { status: 502 },
  )
}
