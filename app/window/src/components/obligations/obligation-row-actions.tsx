"use client"

import * as React from "react"
import { useRouter } from "next/navigation"
import { MoreHorizontal, Pencil, CheckCircle2, Trash2 } from "lucide-react"

import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"

import type { ObligationListItem } from "@/lib/types"

interface ObligationRowActionsProps {
  obligation: ObligationListItem
  onEdit: (obligation: ObligationListItem) => void
}

// Row-level action menu. Mounts as the rightmost cell in each
// obligations-table row. Three actions:
//
//   Edit         - bubbles up to the page-level form dialog via the
//                  onEdit callback. Kept as a callback (not internal
//                  state) so the form dialog lives at the page level
//                  and we don't end up with N copies of it in the DOM.
//   Mark complete- destructive but reversible; one-click with toast-
//                  style confirmation via an inline dialog. POST
//                  /api/obligations/{id}/complete.
//   Delete       - destructive and effectively irreversible (the audit
//                  trail keeps a record, but the operational row is
//                  gone). Confirmation dialog shows the obligation's
//                  title verbatim to force a moment of attention.
//
// router.refresh() after each mutation is the Next.js App Router idiom
// for "re-run the server component data fetch without a full page
// navigation". The server component at /obligations re-calls the BFF
// GET, which re-fetches from the Brain, and the table re-renders with
// the new state. No client-side optimistic updates needed at this
// scale; Brain round-trips are well under a second.

export function ObligationRowActions({
  obligation,
  onEdit,
}: ObligationRowActionsProps) {
  const router = useRouter()

  const [confirmingComplete, setConfirmingComplete] = React.useState(false)
  const [confirmingDelete, setConfirmingDelete] = React.useState(false)
  const [pending, setPending] = React.useState(false)
  const [errorMsg, setErrorMsg] = React.useState<string | null>(null)

  // Already-completed obligations should not expose the "Mark complete"
  // action. Brain accepts it idempotently but showing it would be
  // misleading UX.
  const isAlreadyCompleted = obligation.status === "completed"

  async function handleComplete() {
    setPending(true)
    setErrorMsg(null)
    try {
      const resp = await fetch(
        `/api/obligations/${obligation.obligation_id}/complete`,
        { method: "POST" },
      )
      if (!resp.ok) {
        const body = (await resp.json().catch(() => null)) as
          | { details?: string }
          | null
        setErrorMsg(
          body?.details
            ? `Could not mark complete: ${body.details}`
            : `Could not mark complete (HTTP ${resp.status})`,
        )
        return
      }
      setConfirmingComplete(false)
      router.refresh()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setErrorMsg(`Network error: ${message}`)
    } finally {
      setPending(false)
    }
  }

  async function handleDelete() {
    setPending(true)
    setErrorMsg(null)
    try {
      const resp = await fetch(
        `/api/obligations/${obligation.obligation_id}`,
        { method: "DELETE" },
      )
      if (!resp.ok) {
        const body = (await resp.json().catch(() => null)) as
          | { details?: string }
          | null
        setErrorMsg(
          body?.details
            ? `Could not delete: ${body.details}`
            : `Could not delete (HTTP ${resp.status})`,
        )
        return
      }
      setConfirmingDelete(false)
      router.refresh()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setErrorMsg(`Network error: ${message}`)
    } finally {
      setPending(false)
    }
  }

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button
            variant="ghost"
            size="sm"
            className="size-7 p-0"
            aria-label={`Actions for ${obligation.title}`}
          >
            <MoreHorizontal className="size-4" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-44">
          <DropdownMenuItem
            onSelect={() => onEdit(obligation)}
            className="gap-2"
          >
            <Pencil className="size-4" />
            Edit
          </DropdownMenuItem>
          {!isAlreadyCompleted ? (
            <DropdownMenuItem
              onSelect={() => setConfirmingComplete(true)}
              className="gap-2"
            >
              <CheckCircle2 className="size-4" />
              Mark complete
            </DropdownMenuItem>
          ) : null}
          <DropdownMenuSeparator />
          <DropdownMenuItem
            onSelect={() => setConfirmingDelete(true)}
            className="text-destructive focus:text-destructive gap-2"
          >
            <Trash2 className="size-4" />
            Delete
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>

      {/* Mark-complete confirmation. Soft confirm; no irreversible side
          effects (the obligation row stays, just status/completed_at
          change). One-click confirm. */}
      <Dialog
        open={confirmingComplete}
        onOpenChange={(open) => {
          if (!open) {
            setConfirmingComplete(false)
            setErrorMsg(null)
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Mark obligation as complete?</DialogTitle>
            <DialogDescription>
              This sets the status to <strong>completed</strong> and stamps
              the completion time. An audit blob with the before/after
              snapshot is written to the immutable audit log. You can edit
              the obligation later to revert the status if needed.
            </DialogDescription>
          </DialogHeader>
          <div className="text-muted-foreground py-2 text-sm">
            <span className="font-medium">{obligation.title}</span>
          </div>
          {errorMsg ? (
            <p className="text-destructive text-sm">{errorMsg}</p>
          ) : null}
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setConfirmingComplete(false)}
              disabled={pending}
            >
              Cancel
            </Button>
            <Button onClick={handleComplete} disabled={pending}>
              {pending ? "Marking complete..." : "Mark complete"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      {/* Delete confirmation. The row is removed from the operational
          DB; the audit log keeps the snapshot. Title shown verbatim so
          the user has to read it before clicking the destructive button. */}
      <Dialog
        open={confirmingDelete}
        onOpenChange={(open) => {
          if (!open) {
            setConfirmingDelete(false)
            setErrorMsg(null)
          }
        }}
      >
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Delete obligation?</DialogTitle>
            <DialogDescription>
              The obligation row will be removed from the operational
              database. An audit blob with the full pre-deletion snapshot
              is written to the immutable audit log first, so the
              regulatory trail is preserved. The row itself cannot be
              recovered through the UI.
            </DialogDescription>
          </DialogHeader>
          <div className="text-muted-foreground py-2 text-sm">
            About to delete: <span className="font-medium">{obligation.title}</span>
          </div>
          {errorMsg ? (
            <p className="text-destructive text-sm">{errorMsg}</p>
          ) : null}
          <DialogFooter>
            <Button
              variant="outline"
              onClick={() => setConfirmingDelete(false)}
              disabled={pending}
            >
              Cancel
            </Button>
            <Button
              variant="destructive"
              onClick={handleDelete}
              disabled={pending}
            >
              {pending ? "Deleting..." : "Delete obligation"}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
