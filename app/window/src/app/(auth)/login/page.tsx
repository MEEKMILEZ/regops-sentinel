"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { signIn, confirmSignIn } from "aws-amplify/auth"
import { QRCodeSVG } from "qrcode.react"
import { Copy, Check, ShieldCheck, Loader2 } from "lucide-react"

import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"

// ---------------------------------------------------------------------------
// Login page top-level - tracks which sign-in step we are on and renders
// the matching sub-component. Amplify drives the state machine: each
// signIn / confirmSignIn call returns a nextStep telling us what to do.
//
// Possible flows:
//   email+password -> DONE                                      (rare; pool is MFA-required)
//   email+password -> CONTINUE_SIGN_IN_WITH_TOTP_SETUP -> DONE  (first-time user)
//   email+password -> CONFIRM_SIGN_IN_WITH_TOTP_CODE   -> DONE  (returning user)
// ---------------------------------------------------------------------------

type Step =
  | { kind: "credentials" }
  | { kind: "mfa_code" }
  | { kind: "mfa_enroll"; secret: string; uri: string }
  | { kind: "success" }

export default function LoginPage() {
  const router = useRouter()
  const [step, setStep] = useState<Step>({ kind: "credentials" })

  // Once verification succeeds we briefly show a success card so the user
  // can register the transition (Supabase / WorkOS recommend this), then
  // redirect to the dashboard.
  function completeSignIn() {
    setStep({ kind: "success" })
    setTimeout(() => router.replace("/"), 1500)
  }

  switch (step.kind) {
    case "credentials":
      return <EmailPasswordStep onNextStep={setStep} />
    case "mfa_code":
      return <MfaCodeStep onComplete={completeSignIn} />
    case "mfa_enroll":
      return (
        <MfaEnrollStep
          secret={step.secret}
          uri={step.uri}
          onComplete={completeSignIn}
        />
      )
    case "success":
      return <SuccessStep />
  }
}

// ---------------------------------------------------------------------------
// Step 1 - Email + password
// ---------------------------------------------------------------------------

function EmailPasswordStep({
  onNextStep,
}: {
  onNextStep: (step: Step) => void
}) {
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      const result = await signIn({ username: email, password })
      const stepName = result.nextStep.signInStep

      if (result.isSignedIn || stepName === "DONE") {
        onNextStep({ kind: "success" })
        return
      }

      if (stepName === "CONFIRM_SIGN_IN_WITH_TOTP_CODE") {
        onNextStep({ kind: "mfa_code" })
        return
      }

      if (stepName === "CONTINUE_SIGN_IN_WITH_TOTP_SETUP") {
        // The setup details (sharedSecret + getSetupUri) come back attached
        // to the signIn response itself. Do NOT call setUpTOTP() here;
        // that API is for already-authenticated users adding MFA from a
        // settings page, and would fail with "User needs to be authenticated".
        const details = result.nextStep.totpSetupDetails
        if (!details) {
          setError(
            "Sign-in returned the TOTP setup step without setup details. " +
              "This is unexpected. Please retry.",
          )
          return
        }
        const uri = details.getSetupUri("RegOps Sentinel", email).toString()
        onNextStep({
          kind: "mfa_enroll",
          secret: details.sharedSecret,
          uri,
        })
        return
      }

      // Anything else (NEW_PASSWORD_REQUIRED, RESET_PASSWORD, custom challenges)
      // is unexpected in our current Cognito config. Surface it instead of
      // silently dropping the user.
      setError(`Unexpected sign-in step: ${stepName}`)
    } catch (err) {
      setError(messageFromAuthError(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="text-xl">Sign in to your tenant</CardTitle>
        <CardDescription>
          Use your work email to access RegOps Sentinel.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4" onSubmit={handleSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="tenant">Tenant</Label>
            <Input
              id="tenant"
              type="text"
              defaultValue="acme-meddev"
              readOnly
              className="bg-muted"
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="email">Email</Label>
            <Input
              id="email"
              type="email"
              placeholder="name@acme-meddev.ca"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              required
              autoComplete="email"
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor="password">Password</Label>
            <Input
              id="password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              autoComplete="current-password"
            />
          </div>

          {error && (
            <p className="text-destructive text-sm" role="alert">
              {error}
            </p>
          )}

          <Button type="submit" className="w-full" disabled={busy}>
            {busy && <Loader2 className="mr-2 size-4 animate-spin" />}
            Continue
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Step 2a - MFA code (returning user)
// ---------------------------------------------------------------------------

function MfaCodeStep({ onComplete }: { onComplete: () => void }) {
  const [code, setCode] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      const result = await confirmSignIn({ challengeResponse: code })
      if (result.isSignedIn || result.nextStep.signInStep === "DONE") {
        onComplete()
      } else {
        setError(
          `Unexpected next step after MFA: ${result.nextStep.signInStep}`,
        )
      }
    } catch (err) {
      setError(messageFromAuthError(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="text-xl">Enter your verification code</CardTitle>
        <CardDescription>
          Open your authenticator app and enter the current 6-digit code.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4" onSubmit={handleSubmit}>
          <div className="grid gap-2">
            <Label htmlFor="totp-code">Verification code</Label>
            <Input
              id="totp-code"
              type="text"
              inputMode="numeric"
              autoComplete="one-time-code"
              pattern="[0-9]{6}"
              maxLength={6}
              value={code}
              onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
              required
              autoFocus
              className="text-center font-mono text-lg tracking-widest"
            />
          </div>

          {error && (
            <p className="text-destructive text-sm" role="alert">
              {error}
            </p>
          )}

          <Button type="submit" className="w-full" disabled={busy || code.length !== 6}>
            {busy && <Loader2 className="mr-2 size-4 animate-spin" />}
            Verify and continue
          </Button>
        </form>
      </CardContent>
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Step 2b - MFA enrollment (first-time user)
// ---------------------------------------------------------------------------

function MfaEnrollStep({
  secret,
  uri,
  onComplete,
}: {
  secret: string
  uri: string
  onComplete: () => void
}) {
  const [code, setCode] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [copied, setCopied] = useState(false)

  async function handleCopySecret() {
    try {
      await navigator.clipboard.writeText(secret)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // Clipboard API can fail in non-HTTPS dev environments. The secret
      // is still visible on screen so the user can select and copy manually.
    }
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setBusy(true)
    try {
      // Same confirmSignIn as the returning-user flow, but the nextStep
      // we are responding to is the TOTP setup challenge rather than the
      // ongoing-MFA challenge. Amplify routes by the in-progress session.
      const result = await confirmSignIn({ challengeResponse: code })
      if (result.isSignedIn || result.nextStep.signInStep === "DONE") {
        onComplete()
      } else {
        setError(
          `Unexpected next step after enrollment: ${result.nextStep.signInStep}`,
        )
      }
    } catch (err) {
      setError(messageFromAuthError(err))
    } finally {
      setBusy(false)
    }
  }

  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="text-xl">Set up two-factor authentication</CardTitle>
        <CardDescription>
          Scan this code with Google Authenticator, Authy, or 1Password.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <div className="bg-muted/30 flex justify-center rounded-md border p-4">
          <QRCodeSVG
            value={uri}
            size={176}
            level="M"
            // Force a white background even in dark mode so authenticator
            // app cameras read the code reliably.
            bgColor="#ffffff"
            fgColor="#000000"
          />
        </div>

        <div className="grid gap-1.5">
          <Label className="text-xs">
            Or enter this secret manually
          </Label>
          <div className="flex gap-2">
            <Input
              readOnly
              value={secret}
              className="bg-muted font-mono text-xs"
              onFocus={(e) => e.currentTarget.select()}
            />
            <Button
              type="button"
              variant="outline"
              size="icon"
              onClick={handleCopySecret}
              aria-label="Copy secret"
            >
              {copied ? (
                <Check className="size-4 text-emerald-600" />
              ) : (
                <Copy className="size-4" />
              )}
            </Button>
          </div>
        </div>

        <form className="grid gap-2" onSubmit={handleSubmit}>
          <Label htmlFor="enroll-code">Verification code from your app</Label>
          <Input
            id="enroll-code"
            type="text"
            inputMode="numeric"
            autoComplete="one-time-code"
            pattern="[0-9]{6}"
            maxLength={6}
            value={code}
            onChange={(e) => setCode(e.target.value.replace(/\D/g, ""))}
            required
            autoFocus
            className="text-center font-mono text-lg tracking-widest"
          />

          {error && (
            <p className="text-destructive text-sm" role="alert">
              {error}
            </p>
          )}

          <Button
            type="submit"
            className="mt-2 w-full"
            disabled={busy || code.length !== 6}
          >
            {busy && <Loader2 className="mr-2 size-4 animate-spin" />}
            Verify and enable
          </Button>
        </form>

        <p className="text-muted-foreground text-center text-xs">
          Recovery codes will be issued in the next release (Phase 5).
        </p>
      </CardContent>
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Step 3 - Success
// ---------------------------------------------------------------------------

function SuccessStep() {
  return (
    <Card>
      <CardContent className="flex flex-col items-center gap-3 py-10">
        <div
          className={cn(
            "flex size-12 items-center justify-center rounded-full",
            "bg-emerald-100 text-emerald-600",
            "dark:bg-emerald-950 dark:text-emerald-400",
          )}
        >
          <ShieldCheck className="size-6" />
        </div>
        <p className="text-base font-medium">You are signed in.</p>
        <p className="text-muted-foreground text-sm">Redirecting to your dashboard...</p>
      </CardContent>
    </Card>
  )
}

// ---------------------------------------------------------------------------
// Error mapping. Cognito returns named exceptions; we translate the
// common ones to plain English. Falls back to the raw message so we
// do not hide unexpected failures.
// ---------------------------------------------------------------------------

function messageFromAuthError(err: unknown): string {
  if (err instanceof Error) {
    switch (err.name) {
      case "NotAuthorizedException":
        return "Incorrect email or password."
      case "UserNotFoundException":
        return "No account exists for that email."
      case "UserNotConfirmedException":
        return "Your account has not been confirmed yet."
      case "CodeMismatchException":
        return "That code did not match. Try the next one your app generates."
      case "ExpiredCodeException":
        return "That code expired. Use the latest code from your authenticator."
      case "TooManyRequestsException":
      case "LimitExceededException":
        return "Too many attempts. Wait a moment and try again."
      default:
        return err.message
    }
  }
  return "Sign in failed. Please try again."
}
