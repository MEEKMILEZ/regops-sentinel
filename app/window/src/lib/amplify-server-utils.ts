// Server-side Amplify context.
//
// The adapter's createServerRunner produces a function that runs Amplify
// APIs in an isolated per-request context. The "context" is what lets
// the server read the session cookies that the browser sent, without
// leaking state between requests.
//
// We pass it the same Cognito config the client uses, so server-side
// fetchAuthSession() validates against the same User Pool.

import { createServerRunner } from "@aws-amplify/adapter-nextjs"

export const { runWithAmplifyServerContext } = createServerRunner({
  config: {
    Auth: {
      Cognito: {
        userPoolId: "ca-central-1_3TjLuZRim",
        userPoolClientId: "132om57mrn5k7433dcmt53mfof",
        loginWith: {
          email: true,
        },
        mfa: {
          status: "on",
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
  },
})
