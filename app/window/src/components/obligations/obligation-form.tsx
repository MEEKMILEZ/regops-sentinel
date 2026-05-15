"use client"

import * as React from "react"
import { useRouter } from "next/navigation"

import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"

import type {
  ObligationListItem,
  ObligationType,
  ObligationFrequency,
  ObligationSeverity,
  RegulatoryBody,
} from "@/lib/types"

// Obligation form. Single component handles both Create and Edit modes;
// the mode prop determines which BFF endpoint is hit on submit.
//
// Validation philosophy: the Brain owns canonical validation (required
// fields, enum membership, field interdependencies). Client-side
// validation here is a UX nicety - it surfaces obvious mistakes
// immediately so the user does not burn a network round trip to learn
// "due_at is required when frequency is annual". The Brain catches
// anything client-side validation misses, returning a 422 with details.
//
// Cross-field rules implemented client-side:
//   - title and obligation_type are always required
//   - frequency and severity_if_missed are always required
//   - regulatory_body is always required (no "none" option)
//   - due_at is required UNLESS frequency === "as_required"
//   - device_id is required when obligation_type is mdl_renewal or
//     udi_submission (these obligations are inherently per-device)
//   - title max length 200 chars
//
// HTML5 datetime-local inputs return local time without a TZ. We
// convert to ISO 8601 with offset on submit so the Brain stores
// timezone-aware timestamps (matches the postgres timestamptz column).

interface ObligationFormProps {
  mode: "create" | "edit"
  initialObligation?: ObligationListItem
  open: boolean
  onOpenChange: (open: boolean) => void
}

const OBLIGATION_TYPE_OPTIONS: { value: ObligationType; label: string }[] = [
  { value: "mdl_renewal", label: "MDL renewal" },
  { value: "adverse_event_report", label: "Adverse event report" },
  { value: "recall_notification", label: "Recall notification" },
  { value: "qms_audit", label: "QMS audit" },
  { value: "post_market_surveillance", label: "Post-market surveillance" },
  { value: "udi_submission", label: "UDI submission" },
  { value: "incident_investigation", label: "Incident investigation / RCA" },
]

const FREQUENCY_OPTIONS: { value: ObligationFrequency; label: string }[] = [
  { value: "one_time", label: "One time" },
  { value: "annual", label: "Annual" },
  { value: "quarterly", label: "Quarterly" },
  { value: "monthly", label: "Monthly" },
  { value: "as_required", label: "As required" },
]

const SEVERITY_OPTIONS: { value: ObligationSeverity; label: string }[] = [
  { value: "critical", label: "Critical" },
  { value: "high", label: "High" },
  { value: "medium", label: "Medium" },
  { value: "low", label: "Low" },
]

const REGULATOR_OPTIONS: { value: RegulatoryBody; label: string }[] = [
  { value: "health_canada", label: "Health Canada" },
  { value: "fda", label: "FDA" },
  { value: "iso_auditor", label: "ISO 13485 auditor" },
  { value: "internal_qms", label: "Internal QMS" },
]

function SelectField({
  id,
  label,
  required,
  value,
  onChange,
  options,
  placeholder,
}: {
  id: string
  label: string
  required?: boolean
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
  placeholder?: string
}) {
  return (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor={id}>
        {label}
        {required ? <span className="text-destructive ml-0.5">*</span> : null}
      </Label>
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        className="border-input bg-background ring-offset-background focus-visible:ring-ring flex h-9 w-full rounded-md border px-3 py-1 text-sm focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:outline-none"
      >
        {placeholder !== undefined ? (
          <option value="">{placeholder}</option>
        ) : null}
        {options.map((opt) => (
          <option key={opt.value} value={opt.value}>
            {opt.label}
          </option>
        ))}
      </select>
    </div>
  )
}

function isoToLocalInput(iso: string | null | undefined): string {
  if (!iso) return ""
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ""
  const pad = (n: number) => String(n).padStart(2, "0")
  return (
    `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T` +
    `${pad(d.getHours())}:${pad(d.getMinutes())}`
  )
}

function localInputToIso(local: string): string | null {
  if (!local) return null
  const d = new Date(local)
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString()
}

export function ObligationForm({
  mode,
  initialObligation,
  open,
  onOpenChange,
}: ObligationFormProps) {
  const router = useRouter()

  const [title, setTitle] = React.useState("")
  const [description, setDescription] = React.useState("")
  const [obligationType, setObligationType] = React.useState<string>("")
  const [frequency, setFrequency] = React.useState<string>("")
  const [severity, setSeverity] = React.useState<string>("medium")
  const [regulator, setRegulator] = React.useState<string>("")
  const [dueAtLocal, setDueAtLocal] = React.useState<string>("")
  const [responsibleParty, setResponsibleParty] = React.useState("")
  const [deviceId, setDeviceId] = React.useState<string>("")
  const [notes, setNotes] = React.useState("")

  const [pending, setPending] = React.useState(false)
  const [errorMsg, setErrorMsg] = React.useState<string | null>(null)

  React.useEffect(() => {
    if (!open) return
    setErrorMsg(null)
    setPending(false)
    if (mode === "edit" && initialObligation) {
      setTitle(initialObligation.title ?? "")
      setDescription(initialObligation.description ?? "")
      setObligationType(initialObligation.obligation_type ?? "")
      setFrequency(initialObligation.frequency ?? "")
      setSeverity(initialObligation.severity_if_missed ?? "medium")
      setRegulator(initialObligation.regulatory_body ?? "")
      setDueAtLocal(isoToLocalInput(initialObligation.due_at))
      setResponsibleParty(initialObligation.responsible_party ?? "")
      setDeviceId(
        initialObligation.device_id != null
          ? String(initialObligation.device_id)
          : "",
      )
      setNotes(initialObligation.notes ?? "")
    } else {
      setTitle("")
      setDescription("")
      setObligationType("")
      setFrequency("")
      setSeverity("medium")
      setRegulator("")
      setDueAtLocal("")
      setResponsibleParty("")
      setDeviceId("")
      setNotes("")
    }
  }, [open, mode, initialObligation])

  const dueAtRequired = frequency !== "" && frequency !== "as_required"
  const deviceRequired =
    obligationType === "mdl_renewal" || obligationType === "udi_submission"

  function validate(): string | null {
    if (!title.trim()) return "Title is required."
    if (title.length > 200) return "Title must be 200 characters or fewer."
    if (!obligationType) return "Obligation type is required."
    if (!frequency) return "Frequency is required."
    if (!severity) return "Severity is required."
    if (!regulator) return "Regulatory body is required."
    if (dueAtRequired && !dueAtLocal) {
      return "Due date is required unless frequency is 'As required'."
    }
    if (deviceRequired && !deviceId.trim()) {
      return "Device ID is required for MDL renewals and UDI submissions."
    }
    if (deviceId.trim() && Number.isNaN(Number(deviceId))) {
      return "Device ID must be a number."
    }
    return null
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    const validationError = validate()
    if (validationError) {
      setErrorMsg(validationError)
      return
    }

    setPending(true)
    setErrorMsg(null)

    const payload: Record<string, unknown> = {
      title: title.trim(),
      obligation_type: obligationType,
      frequency,
      severity_if_missed: severity,
      regulatory_body: regulator,
      description: description.trim() || null,
      responsible_party: responsibleParty.trim() || null,
      notes: notes.trim() || null,
      device_id: deviceId.trim() ? Number(deviceId) : null,
      due_at: localInputToIso(dueAtLocal),
    }

    const url =
      mode === "create"
        ? "/api/obligations"
        : `/api/obligations/${initialObligation?.obligation_id}`
    const method = mode === "create" ? "POST" : "PATCH"

    try {
      const resp = await fetch(url, {
        method,
        headers: { "content-type": "application/json" },
        body: JSON.stringify(payload),
      })
      if (!resp.ok) {
        const body = (await resp.json().catch(() => null)) as
          | { details?: string }
          | null
        setErrorMsg(
          body?.details
            ? `Save failed: ${body.details}`
            : `Save failed (HTTP ${resp.status})`,
        )
        return
      }
      onOpenChange(false)
      router.refresh()
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err)
      setErrorMsg(`Network error: ${message}`)
    } finally {
      setPending(false)
    }
  }

  const titleText =
    mode === "create" ? "New regulatory obligation" : "Edit obligation"
  const submitText = mode === "create" ? "Create obligation" : "Save changes"

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-h-[90vh] overflow-y-auto sm:max-w-2xl">
        <DialogHeader>
          <DialogTitle>{titleText}</DialogTitle>
          <DialogDescription>
            Required fields are marked with{" "}
            <span className="text-destructive">*</span>.
          </DialogDescription>
        </DialogHeader>

        <form onSubmit={handleSubmit} className="flex flex-col gap-4 pt-2">
          <div className="flex flex-col gap-1.5">
            <Label htmlFor="title">
              Title<span className="text-destructive ml-0.5">*</span>
            </Label>
            <Input
              id="title"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              maxLength={200}
              placeholder="e.g. Annual MDL renewal - GlucoTrack 2000"
              required
            />
            <span className="text-muted-foreground text-xs">
              {title.length}/200
            </span>
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <SelectField
              id="obligation_type"
              label="Obligation type"
              required
              value={obligationType}
              onChange={setObligationType}
              options={OBLIGATION_TYPE_OPTIONS}
              placeholder="Select type..."
            />
            <SelectField
              id="frequency"
              label="Frequency"
              required
              value={frequency}
              onChange={setFrequency}
              options={FREQUENCY_OPTIONS}
              placeholder="Select frequency..."
            />
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <SelectField
              id="severity"
              label="Severity if missed"
              required
              value={severity}
              onChange={setSeverity}
              options={SEVERITY_OPTIONS}
            />
            <SelectField
              id="regulator"
              label="Regulatory body"
              required
              value={regulator}
              onChange={setRegulator}
              options={REGULATOR_OPTIONS}
              placeholder="Select regulator..."
            />
          </div>

          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="due_at">
                Due date
                {dueAtRequired ? (
                  <span className="text-destructive ml-0.5">*</span>
                ) : (
                  <span className="text-muted-foreground ml-1 text-xs">
                    (optional for "as required")
                  </span>
                )}
              </Label>
              <Input
                id="due_at"
                type="datetime-local"
                value={dueAtLocal}
                onChange={(e) => setDueAtLocal(e.target.value)}
              />
            </div>
            <div className="flex flex-col gap-1.5">
              <Label htmlFor="device_id">
                Device ID
                {deviceRequired ? (
                  <span className="text-destructive ml-0.5">*</span>
                ) : (
                  <span className="text-muted-foreground ml-1 text-xs">
                    (optional)
                  </span>
                )}
              </Label>
              <Input
                id="device_id"
                type="number"
                value={deviceId}
                onChange={(e) => setDeviceId(e.target.value)}
                placeholder="e.g. 42"
                min={1}
              />
              <span className="text-muted-foreground text-xs">
                Look up the numeric device ID from the Devices page.
              </span>
            </div>
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="responsible_party">Responsible party</Label>
            <Input
              id="responsible_party"
              value={responsibleParty}
              onChange={(e) => setResponsibleParty(e.target.value)}
              placeholder="e.g. Quality Manager, Dr. Sarah Park"
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="description">Description</Label>
            <textarea
              id="description"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              rows={2}
              placeholder="One-sentence summary of what this obligation requires."
              className="border-input bg-background ring-offset-background focus-visible:ring-ring flex w-full rounded-md border px-3 py-2 text-sm focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:outline-none"
            />
          </div>

          <div className="flex flex-col gap-1.5">
            <Label htmlFor="notes">Notes</Label>
            <textarea
              id="notes"
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              rows={3}
              placeholder="Free-form notes - internal context, links to upstream documents, etc."
              className="border-input bg-background ring-offset-background focus-visible:ring-ring flex w-full rounded-md border px-3 py-2 text-sm focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:outline-none"
            />
          </div>

          {errorMsg ? (
            <p className="text-destructive text-sm" role="alert">
              {errorMsg}
            </p>
          ) : null}

          <DialogFooter className="pt-2">
            <Button
              type="button"
              variant="outline"
              onClick={() => onOpenChange(false)}
              disabled={pending}
            >
              Cancel
            </Button>
            <Button type="submit" disabled={pending}>
              {pending ? "Saving..." : submitText}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}