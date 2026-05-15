"use client"

import * as React from "react"
import { useRouter } from "next/navigation"
import { Search, Loader2, Bell, Boxes, ClipboardList } from "lucide-react"

import { Input } from "@/components/ui/input"
import { cn } from "@/lib/utils"

import type { SearchResponse, SearchResultItem } from "@/lib/types"

// Debounced, dropdown-style global search. Hits /api/search whenever
// the input changes (after a 200ms quiet period). Results are grouped
// visually by kind (alert/device/obligation) and ordered by ts_rank
// across all three. Click navigates to the relevant detail or list
// page; ESC clears; clicking outside closes the dropdown.

const DEBOUNCE_MS = 200

export function SearchBar() {
  const router = useRouter()
  const [query, setQuery] = React.useState("")
  const [results, setResults] = React.useState<SearchResultItem[]>([])
  const [loading, setLoading] = React.useState(false)
  const [open, setOpen] = React.useState(false)
  const [focusedIndex, setFocusedIndex] = React.useState(-1)
  const containerRef = React.useRef<HTMLDivElement>(null)
  const abortRef = React.useRef<AbortController | null>(null)

  // Debounce: re-fetch only after the user has stopped typing for
  // DEBOUNCE_MS. Cancels in-flight requests with AbortController so a
  // slow earlier query can't overwrite a fast later one.
  React.useEffect(() => {
    const trimmed = query.trim()
    if (!trimmed) {
      setResults([])
      setLoading(false)
      return
    }
    setLoading(true)
    const timer = setTimeout(async () => {
      // Cancel any in-flight request from a prior keystroke.
      if (abortRef.current) abortRef.current.abort()
      const controller = new AbortController()
      abortRef.current = controller
      try {
        const res = await fetch(
          `/api/search?q=${encodeURIComponent(trimmed)}`,
          { signal: controller.signal, cache: "no-store" },
        )
        if (!res.ok) {
          setResults([])
          setLoading(false)
          return
        }
        const data: SearchResponse = await res.json()
        setResults(data.results)
        setLoading(false)
        setOpen(true)
        setFocusedIndex(-1)
      } catch (err) {
        // AbortError is expected on rapid keystrokes; ignore.
        if ((err as Error).name !== "AbortError") {
          setResults([])
          setLoading(false)
        }
      }
    }, DEBOUNCE_MS)
    return () => clearTimeout(timer)
  }, [query])

  // Close dropdown when clicking outside the search container.
  React.useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (
        containerRef.current &&
        !containerRef.current.contains(e.target as Node)
      ) {
        setOpen(false)
      }
    }
    document.addEventListener("mousedown", handleClick)
    return () => document.removeEventListener("mousedown", handleClick)
  }, [])

  function handleSelect(item: SearchResultItem) {
    setOpen(false)
    setQuery("")
    router.push(item.url)
  }

  function handleKeyDown(e: React.KeyboardEvent<HTMLInputElement>) {
    if (!open || results.length === 0) {
      if (e.key === "Escape") {
        setQuery("")
        setOpen(false)
      }
      return
    }
    if (e.key === "ArrowDown") {
      e.preventDefault()
      setFocusedIndex((i) => Math.min(i + 1, results.length - 1))
    } else if (e.key === "ArrowUp") {
      e.preventDefault()
      setFocusedIndex((i) => Math.max(i - 1, 0))
    } else if (e.key === "Enter") {
      e.preventDefault()
      const idx = focusedIndex >= 0 ? focusedIndex : 0
      handleSelect(results[idx])
    } else if (e.key === "Escape") {
      setOpen(false)
      setQuery("")
    }
  }

  const showDropdown =
    open &&
    query.trim().length > 0 &&
    (loading || results.length > 0 || (!loading && results.length === 0))

  return (
    <div
      ref={containerRef}
      className="relative ml-auto flex w-full max-w-sm items-center gap-2"
    >
      <div className="relative w-full">
        <Search className="text-muted-foreground absolute top-1/2 left-2.5 size-4 -translate-y-1/2" />
        {loading ? (
          <Loader2 className="text-muted-foreground absolute top-1/2 right-2.5 size-4 -translate-y-1/2 animate-spin" />
        ) : null}
        <Input
          placeholder="Search alerts, devices, obligations..."
          className="w-full pl-8"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setOpen(true)
          }}
          onFocus={() => {
            if (query.trim() && results.length > 0) setOpen(true)
          }}
          onKeyDown={handleKeyDown}
          aria-label="Search"
          aria-autocomplete="list"
          aria-expanded={showDropdown}
        />
      </div>

      {showDropdown ? (
        <div
          role="listbox"
          className="bg-popover border-border absolute top-full right-0 left-0 z-40 mt-1 max-h-96 overflow-auto rounded-md border shadow-md"
        >
          {loading && results.length === 0 ? (
            <div className="text-muted-foreground px-3 py-4 text-center text-xs">
              Searching...
            </div>
          ) : results.length === 0 ? (
            <div className="text-muted-foreground px-3 py-4 text-center text-xs">
              No matches for "{query.trim()}"
            </div>
          ) : (
            <ul>
              {results.map((item, idx) => (
                <li key={`${item.kind}-${item.id}`}>
                  <button
                    type="button"
                    onClick={() => handleSelect(item)}
                    onMouseEnter={() => setFocusedIndex(idx)}
                    role="option"
                    aria-selected={focusedIndex === idx}
                    className={cn(
                      "hover:bg-muted/60 flex w-full items-start gap-2 px-3 py-2 text-left text-sm transition-colors",
                      focusedIndex === idx && "bg-muted/60",
                    )}
                  >
                    <span className="text-muted-foreground mt-0.5">
                      {kindIcon(item.kind)}
                    </span>
                    <div className="flex min-w-0 flex-1 flex-col">
                      <span className="truncate font-medium">
                        {item.title}
                      </span>
                      {item.subtitle ? (
                        <span className="text-muted-foreground truncate text-xs">
                          {item.subtitle}
                        </span>
                      ) : null}
                    </div>
                    <div className="flex shrink-0 flex-col items-end gap-0.5">
                      <span className="text-muted-foreground text-[10px] uppercase">
                        {kindLabel(item.kind)}
                      </span>
                      {item.badge ? (
                        <span className="text-muted-foreground text-[10px]">
                          {item.badge}
                        </span>
                      ) : null}
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
      ) : null}
    </div>
  )
}

function kindIcon(kind: string): React.ReactNode {
  const cls = "size-3.5"
  switch (kind) {
    case "alert":
      return <Bell className={cls} />
    case "device":
      return <Boxes className={cls} />
    case "obligation":
      return <ClipboardList className={cls} />
    default:
      return <Search className={cls} />
  }
}

function kindLabel(kind: string): string {
  switch (kind) {
    case "alert":
      return "Alert"
    case "device":
      return "Device"
    case "obligation":
      return "Obligation"
    default:
      return kind
  }
}
