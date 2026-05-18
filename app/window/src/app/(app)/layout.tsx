import { SidebarInset, SidebarProvider } from "@/components/ui/sidebar"

import { AppSidebar } from "@/components/app-sidebar"
import { SiteHeader } from "@/components/site-header"

import { getCurrentUserClaims, formatTenantDisplay } from "@/lib/bff"

// Server component so we can read the Cognito ID token from the
// encrypted server cookie. Claims flow down to the sidebar (for the
// tenant label) and to any other layout-level chrome that needs them.
export default async function AppLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  const claims = await getCurrentUserClaims()
  const tenantDisplay = claims ? formatTenantDisplay(claims.tenantId) : ""

  return (
    <SidebarProvider>
      <AppSidebar tenantDisplay={tenantDisplay} />
      <SidebarInset>
        <SiteHeader />
        <main className="flex-1 p-6">{children}</main>
      </SidebarInset>
    </SidebarProvider>
  )
}
