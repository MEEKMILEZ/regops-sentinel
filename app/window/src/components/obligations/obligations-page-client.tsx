"use client"

import * as React from "react"
import { Plus } from "lucide-react"

import { Button } from "@/components/ui/button"

import { ObligationsTable } from "@/components/obligations/obligations-table"
import { ObligationForm } from "@/components/obligations/obligation-form"
import type { ObligationListItem } from "@/lib/types"

interface ObligationsPageClientProps {
  obligations: ObligationListItem[]
}

// Page-level wrapper that owns the form dialog state. Receives the
// server-fetched obligations list as a prop. The table renders the
// rows and bubbles row-actions edit clicks up to here; this component
// owns the single form instance and toggles between create-mode (from
// the New button) and edit-mode (from a row's edit menu).

type EditingObligation = ObligationListItem | undefined

export function ObligationsPageClient({
  obligations,
}: ObligationsPageClientProps) {
  const [formOpen, setFormOpen] = React.useState(false)
  const [formMode, setFormMode] = React.useState<"create" | "edit">("create")
  const [editingObligation, setEditingObligation] =
    React.useState<EditingObligation>(undefined)

  function handleNewClick() {
    setFormMode("create")
    setEditingObligation(undefined)
    setFormOpen(true)
  }

  function handleEditClick(obligation: ObligationListItem) {
    setFormMode("edit")
    setEditingObligation(obligation)
    setFormOpen(true)
  }

  return (
    <>
      <div className="flex items-center justify-end">
        <Button size="sm" onClick={handleNewClick} className="gap-2">
          <Plus className="size-4" />
          New obligation
        </Button>
      </div>

      <ObligationsTable obligations={obligations} onEdit={handleEditClick} />

      <ObligationForm
        mode={formMode}
        initialObligation={editingObligation}
        open={formOpen}
        onOpenChange={setFormOpen}
      />
    </>
  )
}