import Link from "next/link"

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

export default function LoginPage() {
  return (
    <Card>
      <CardHeader className="text-center">
        <CardTitle className="text-xl">Sign in to your tenant</CardTitle>
        <CardDescription>
          Use your work email to access RegOps Sentinel.
        </CardDescription>
      </CardHeader>
      <CardContent>
        <form className="grid gap-4">
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
              required
            />
          </div>
          <div className="grid gap-2">
            <div className="flex items-center">
              <Label htmlFor="password">Password</Label>
              <Link
                href="#"
                className="text-muted-foreground ml-auto text-xs hover:underline"
              >
                Forgot password?
              </Link>
            </div>
            <Input id="password" type="password" required />
          </div>
          <Button type="submit" className="w-full">
            Continue
          </Button>
        </form>
        <p className="text-muted-foreground mt-6 text-center text-xs">
          Authentication wiring lands in Stage D (Cognito MFA).
          <br />
          This page is currently a static placeholder.
        </p>
      </CardContent>
    </Card>
  )
}
