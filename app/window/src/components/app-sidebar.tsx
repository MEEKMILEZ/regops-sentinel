"use client"

import * as React from "react"
import Link from "next/link"
import { useRouter, usePathname } from "next/navigation"
import { signOut, getCurrentUser, fetchUserAttributes } from "aws-amplify/auth"
import {
  LayoutDashboard,
  Bell,
  FileText,
  Boxes,
  Shield,
  Settings,
  LogOut,
  ChevronUp,
  User,
} from "lucide-react"

import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarGroupLabel,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

// Navigation items shown in the main sidebar group.
// Only routes that are actually wired and gated render here. Obligations
// remains intentionally omitted until Phase 5C ships; showing a link
// that 404s would be worse than not showing it at all. Audit log
// shipped in Phase 5A, Devices catalog (read-only) shipped in Phase 5B.
const navItems = [
  { title: "Dashboard", url: "/", icon: LayoutDashboard },
  { title: "Alerts", url: "/alerts", icon: Bell },
  { title: "Devices", url: "/devices", icon: Boxes },
  { title: "Audit log", url: "/audit", icon: FileText },
]

interface SessionUser {
  name: string
  role: string
}

const FALLBACK_USER: SessionUser = {
  name: "Guest",
  role: "Not signed in",
}

export function AppSidebar() {
  const pathname = usePathname()
  const router = useRouter()
  const [sessionUser, setSessionUser] =
    React.useState<SessionUser>(FALLBACK_USER)
  const [signingOut, setSigningOut] = React.useState(false)

  // Read the signed-in user's display name and tenant_role from Cognito
  // on mount. If no session exists (route protection should normally
  // prevent this, but during sign-out transitions it can happen briefly)
  // we keep the fallback values.
  React.useEffect(() => {
    let cancelled = false
    async function loadUser() {
      try {
        await getCurrentUser()
        const attrs = await fetchUserAttributes()
        if (cancelled) return
        const name = attrs.name ?? attrs.email ?? "User"
        // tenant_role is stored under a "custom:" prefix.
        const rawRole = attrs["custom:tenant_role"] ?? ""
        const role = rawRole
          ? rawRole.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase())
          : "Member"
        setSessionUser({ name, role })
      } catch {
        // No active session - leave the fallback values.
      }
    }
    loadUser()
    return () => {
      cancelled = true
    }
  }, [])

  async function handleSignOut() {
    if (signingOut) return
    setSigningOut(true)
    try {
      await signOut()
    } catch {
      // Even if Amplify reports a failure, redirect to /login. The user
      // intent was clear and a hung session is better forced out than
      // left in an ambiguous state.
    } finally {
      router.replace("/login")
    }
  }

  const initial = sessionUser.name?.charAt(0)?.toUpperCase() ?? "?"

  return (
    <Sidebar>
      <SidebarHeader>
        <SidebarMenu>
          <SidebarMenuItem>
            <SidebarMenuButton size="lg" asChild>
              <Link href="/">
                <div className="bg-primary text-primary-foreground flex aspect-square size-8 items-center justify-center rounded-md">
                  <Shield className="size-4" />
                </div>
                <div className="flex flex-col gap-0.5 leading-none">
                  <span className="font-semibold">RegOps Sentinel</span>
                  <span className="text-muted-foreground text-xs">
                    Acme MedDev
                  </span>
                </div>
              </Link>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupLabel>Platform</SidebarGroupLabel>
          <SidebarGroupContent>
            <SidebarMenu>
              {navItems.map((item) => {
                const isActive =
                  pathname === item.url ||
                  (item.url !== "/" && pathname.startsWith(item.url))
                return (
                  <SidebarMenuItem key={item.title}>
                    <SidebarMenuButton asChild isActive={isActive}>
                      <Link href={item.url}>
                        <item.icon />
                        <span>{item.title}</span>
                      </Link>
                    </SidebarMenuButton>
                  </SidebarMenuItem>
                )
              })}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter>
        <SidebarMenu>
          <SidebarMenuItem>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <SidebarMenuButton size="lg">
                  <div className="bg-sidebar-accent flex aspect-square size-8 items-center justify-center rounded-md text-sm font-medium">
                    {initial !== "?" ? (
                      initial
                    ) : (
                      <User className="size-4" />
                    )}
                  </div>
                  <div className="flex flex-col gap-0.5 text-left leading-none">
                    <span className="text-sm font-medium">
                      {sessionUser.name}
                    </span>
                    <span className="text-muted-foreground text-xs">
                      {sessionUser.role}
                    </span>
                  </div>
                  <ChevronUp className="ml-auto size-4" />
                </SidebarMenuButton>
              </DropdownMenuTrigger>
              <DropdownMenuContent side="top" align="end" className="w-56">
                <DropdownMenuItem disabled>
                  <Settings className="mr-2 size-4" />
                  Account settings
                </DropdownMenuItem>
                <DropdownMenuSeparator />
                <DropdownMenuItem
                  onSelect={handleSignOut}
                  disabled={signingOut}
                >
                  <LogOut className="mr-2 size-4" />
                  {signingOut ? "Signing out..." : "Sign out"}
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </Sidebar>
  )
}
