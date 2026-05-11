// Server-side route protection (Next.js 16 "proxy" file - was middleware.ts
// in older versions).
//
// Runs before any page renders. We read the request's cookies, ask Amplify
// to validate them server-side, and:
//   - If the user is signed in and visits /login, redirect them to /
//   - If the user is NOT signed in and visits a protected route, redirect
//     them to /login
//   - Otherwise pass through
//
// Static assets, the Next.js internal routes, and API routes are excluded
// via the matcher at the bottom of this file.

import { NextRequest, NextResponse } from "next/server"
import { fetchAuthSession } from "aws-amplify/auth/server"

import { runWithAmplifyServerContext } from "@/lib/amplify-server-utils"

export async function proxy(request: NextRequest) {
  const response = NextResponse.next()

  const isSignedIn = await runWithAmplifyServerContext({
    nextServerContext: { request, response },
    operation: async (contextSpec) => {
      try {
        const session = await fetchAuthSession(contextSpec)
        // A valid session has both tokens. Either being missing means the
        // user is not authenticated for our purposes.
        return (
          session.tokens?.accessToken !== undefined &&
          session.tokens?.idToken !== undefined
        )
      } catch {
        return false
      }
    },
  })

  const path = request.nextUrl.pathname
  const isLoginRoute = path === "/login" || path.startsWith("/login/")

  if (isSignedIn && isLoginRoute) {
    // Already signed in - no reason to see the login form.
    return NextResponse.redirect(new URL("/", request.url))
  }

  if (!isSignedIn && !isLoginRoute) {
    // Protected route, no session - send to login.
    return NextResponse.redirect(new URL("/login", request.url))
  }

  return response
}

// The matcher tells Next.js which paths this proxy runs on. We exclude:
//   - /_next/* (Next.js internal assets and HMR)
//   - /api/* (we'll add per-route auth in Stage E)
//   - Files with a dot in the path segment (favicon.ico, .png, .svg, etc.)
//
// Everything else - all the page routes - runs through the proxy.
export const config = {
  matcher: ["/((?!api|_next/static|_next/image|favicon.ico|.*\\.).*)"],
}
