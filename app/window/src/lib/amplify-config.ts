// Amplify configuration for RegOps Sentinel.
//
// These values are public (the User Pool ID and the web app client ID
// are not secrets - they identify a public-facing auth surface). The
// real security boundary is enforced server-side by Cognito itself
// (password policy, MFA, JWT signatures, token lifetimes).
//
// In Stage E, when we add server-side BFF route handlers that verify
// JWTs and call the Brain, we will move these values to environment
// variables and add the @aws-amplify/adapter-nextjs adapter for
// server-side Amplify usage. For Stage D (client-only sign-in flow),
// this static object is enough.

import { Amplify } from "aws-amplify"

const AMPLIFY_CONFIG = {
  Auth: {
    Cognito: {
      userPoolId: "ca-central-1_3TjLuZRim",
      userPoolClientId: "132om57mrn5k7433dcmt53mfof",
      loginWith: {
        email: true,
      },
      mfa: {
        status: "on" as const,
        totpEnabled: true,
        smsEnabled: false,
      },
      passwordFormat: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireNumbers: true,
        requireSpecialCharacters: true,
      },
    },
  },
}

let configured = false

export function configureAmplify(): void {
  if (configured) return
  Amplify.configure(AMPLIFY_CONFIG, { ssr: true })
  configured = true
}
