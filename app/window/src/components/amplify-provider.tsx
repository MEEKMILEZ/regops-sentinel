"use client"

import { useEffect } from "react"

import { configureAmplify } from "@/lib/amplify-config"

// Tiny client component whose only job is to call configureAmplify()
// exactly once when the app boots in the browser. We render this once
// in the root layout so every page in the app has Amplify available
// before any auth API is called.
//
// We avoid calling configureAmplify() at module top-level (i.e. outside
// any component) because that would run during server rendering too,
// where Amplify has no browser globals to bind to.
export function AmplifyClientInit() {
  useEffect(() => {
    configureAmplify()
  }, [])

  return null
}
