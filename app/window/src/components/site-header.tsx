"use client"

import * as React from "react"
import { usePathname } from "next/navigation"

import { Separator } from "@/components/ui/separator"

import { SearchBar } from "@/components/search/search-bar"
import { SidebarTrigger } from "@/components/ui/sidebar"

// Maps top-level URL segments to human-friendly page titles.
// Add new entries here as new pages are introduced.
const pageTitles: Record<string, string> = {
  "": "Dashboard",
  alerts: "Alerts",
  obligations: "Obligations",
  devices: "Devices",
  audit: "Audit Log",
}

function deriveTitle(pathname: string): string {
  const firstSegment = pathname.split("/").filter(Boolean)[0] ?? ""
  return pageTitles[firstSegment] ?? "RegOps Sentinel"
}

export function SiteHeader() {
  const pathname = usePathname()
  const title = deriveTitle(pathname)

  return (
    <header className="bg-background sticky top-0 z-30 flex h-14 shrink-0 items-center gap-2 border-b px-4">
      <SidebarTrigger className="-ml-1" />
      <Separator orientation="vertical" className="h-4" />
      <h1 className="text-sm font-medium">{title}</h1>
      <SearchBar />
    </header>
  )
}
