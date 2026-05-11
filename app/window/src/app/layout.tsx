import type { Metadata } from "next"

import { TooltipProvider } from "@/components/ui/tooltip"

import { AmplifyClientInit } from "@/components/amplify-provider"

import "./globals.css"

export const metadata: Metadata = {
  title: "RegOps Sentinel",
  description:
    "Regulatory intelligence platform for Canadian medical device distributors.",
}

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode
}>) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body className="antialiased">
        <AmplifyClientInit />
        <TooltipProvider>{children}</TooltipProvider>
      </body>
    </html>
  )
}
