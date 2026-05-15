"use client"

import * as React from "react"
import { ChevronLeft, ChevronRight, AlertTriangle } from "lucide-react"

import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table"
import { cn } from "@/lib/utils"

import type { DeviceListItem } from "@/lib/types"

interface DevicesTableProps {
  devices: DeviceListItem[]
}

const PAGE_SIZE = 10

// Client-side pagination over an already-fetched array. The server
// component fetches up to limit=100 from the Brain and hands the full
// set to this component. State lives in React; no URL params.
//
// When/if a tenant accumulates more than 100 devices regularly, swap
// for cursor-based pagination via a Brain change.

export function DevicesTable({ devices }: DevicesTableProps) {
  // Already sorted by class asc + brand asc upstream; we trust that order.
  const [page, setPage] = React.useState(0)

  const totalPages = Math.max(1, Math.ceil(devices.length / PAGE_SIZE))
  const safePage = Math.min(page, totalPages - 1)
  const startIdx = safePage * PAGE_SIZE
  const endIdx = Math.min(startIdx + PAGE_SIZE, devices.length)
  const visible = devices.slice(startIdx, endIdx)

  const canPrev = safePage > 0
  const canNext = safePage < totalPages - 1

  return (
    <div className="flex flex-col gap-3">
      <div className="text-muted-foreground flex items-center justify-between text-xs">
        <span>
          {devices.length === 0
            ? "No devices in catalog"
            : `Showing ${startIdx + 1}-${endIdx} of ${devices.length}`}
        </span>
        <span>
          Page {safePage + 1} of {totalPages}
        </span>
      </div>

      <Table>
        <TableHeader>
          <TableRow>
            <TableHead className="w-[60px]">Class</TableHead>
            <TableHead>Brand</TableHead>
            <TableHead>Manufacturer</TableHead>
            <TableHead className="w-[140px]">UDI-DI</TableHead>
            <TableHead className="w-[100px]">MDL</TableHead>
            <TableHead className="w-[120px]">Clearance</TableHead>
            <TableHead className="w-[110px]">Status</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {visible.length === 0 ? (
            <TableRow>
              <TableCell
                colSpan={7}
                className="text-muted-foreground py-8 text-center text-sm"
              >
                No devices in catalog yet. Phase 5B.2 will add CSV upload.
              </TableCell>
            </TableRow>
          ) : (
            visible.map((row) => (
              <TableRow key={row.device_id} className="hover:bg-muted/40">
                <TableCell>
                  <Badge variant={deviceClassVariant(row.device_class)}>
                    {row.device_class}
                  </Badge>
                </TableCell>
                <TableCell>
                  <div className="flex flex-col">
                    <span className="font-medium">{row.brand_name}</span>
                    {row.model_number ? (
                      <span className="text-muted-foreground font-mono text-xs">
                        Model {row.model_number}
                      </span>
                    ) : null}
                  </div>
                </TableCell>
                <TableCell className="text-sm">{row.manufacturer}</TableCell>
                <TableCell className="text-muted-foreground font-mono text-xs">
                  {row.di}
                </TableCell>
                <TableCell className="text-muted-foreground font-mono text-xs">
                  {row.mdl_number || "—"}
                </TableCell>
                <TableCell className="text-muted-foreground text-xs">
                  {row.clearance_type || "—"}
                </TableCell>
                <TableCell>
                  <span
                    className={cn(
                      "inline-flex items-center gap-1 text-xs",
                      statusToneClass(row.status),
                    )}
                  >
                    {row.status === "recalled" ? (
                      <AlertTriangle className="size-3" />
                    ) : null}
                    {humanStatus(row.status)}
                  </span>
                </TableCell>
              </TableRow>
            ))
          )}
        </TableBody>
      </Table>

      <div className="flex items-center justify-end gap-2 pt-1">
        <Button
          size="sm"
          variant="outline"
          onClick={() => setPage((p) => Math.max(0, p - 1))}
          disabled={!canPrev}
          aria-label="Previous page"
        >
          <ChevronLeft className="size-4" />
          Previous
        </Button>
        <Button
          size="sm"
          variant="outline"
          onClick={() => setPage((p) => Math.min(totalPages - 1, p + 1))}
          disabled={!canNext}
          aria-label="Next page"
        >
          Next
          <ChevronRight className="size-4" />
        </Button>
      </div>
    </div>
  )
}

function deviceClassVariant(
  c: string,
): "default" | "secondary" | "outline" | "destructive" {
  // Higher class = more regulatory burden = stronger visual weight
  switch (c) {
    case "IV":
      return "destructive"
    case "III":
      return "default"
    case "II":
      return "secondary"
    case "I":
      return "outline"
    default:
      return "outline"
  }
}

function statusToneClass(status: string): string {
  switch (status) {
    case "recalled":
      return "text-destructive font-medium"
    case "discontinued":
      return "text-muted-foreground italic"
    case "pending":
      return "text-amber-600"
    case "active":
    default:
      return "text-foreground"
  }
}

function humanStatus(status: string): string {
  switch (status) {
    case "active":
      return "Active"
    case "recalled":
      return "Recalled"
    case "discontinued":
      return "Discontinued"
    case "pending":
      return "Pending"
    default:
      return status
  }
}
