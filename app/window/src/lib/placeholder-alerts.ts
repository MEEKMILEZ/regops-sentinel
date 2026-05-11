// Shared placeholder alerts dataset.
// Both the alerts list page and the alert detail page import from here.
// In Stage E, this file is replaced by a `fetchAlerts(tenantId)` function
// that calls the BFF route, which in turn calls the Brain `/alerts` endpoint.

export type Classification = "RELEVANT" | "NEEDS_REVIEW" | "NOT_RELEVANT"
export type Urgency = "CRITICAL" | "HIGH" | "MEDIUM" | "LOW"
export type Source =
  | "Health Canada Recalls"
  | "Health Canada Shortages"
  | "MedEffect"

export interface Alert {
  id: string
  externalId: string
  title: string
  source: Source
  urgency: Urgency
  classification: Classification
  classifiedAt: string
  ago: string
  body: string
  sourceUrl: string
  categories: string[]
  confidence: number
  reasoning: string
  auditPath: string
  auditVersionId: string
  kmsKeyAlias: string
}

export const alerts: Alert[] = [
  {
    id: "rec-82041",
    externalId: "RA-82041",
    title: "Class I recall — cardiac stent migration risk",
    source: "Health Canada Recalls",
    urgency: "CRITICAL",
    classification: "RELEVANT",
    classifiedAt: "2026-05-10T05:42:00Z",
    ago: "2h ago",
    body: "Health Canada has issued a Class I recall for a coronary stent manufactured by a third-party supplier after post-market surveillance identified a higher than expected rate of stent migration in patients with bifurcated lesions. Affected lot numbers span manufacture dates from 2024-Q3 onwards. Distributors are required to quarantine remaining inventory, contact implanting facilities, and submit a 24-hour acknowledgement to the Compliance and Enforcement Directorate.",
    sourceUrl:
      "https://recalls-rappels.canada.ca/en/alert-recall/example-cardiac-stent-recall",
    categories: ["cardiology-devices", "implantables"],
    confidence: 1.0,
    reasoning:
      "Class I recall under Canadian Medical Device Regulations. Affects an implantable cardiology device that matches Acme MedDev's product catalog category 'cardiology-devices'. Urgency CRITICAL because reporting obligations attach within 24 hours.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/10/health-canada-recalls_82041_05420032.json",
    auditVersionId: "Vx7p9KqW2HnLm3jBcXyZ",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82042",
    externalId: "DS-82042",
    title: "Insulin Glargine — extended drug shortage",
    source: "Health Canada Shortages",
    urgency: "CRITICAL",
    classification: "RELEVANT",
    classifiedAt: "2026-05-10T03:18:00Z",
    ago: "4h ago",
    body: "The Drug Shortages Canada portal has been updated to indicate an extended shortage of long-acting insulin glargine 100 U/mL, affecting both 10 mL vials and 3 mL prefilled pens. Anticipated resolution is no earlier than Q3 2026. Hospitals and clinics that rely on devices and consumables for insulin delivery (pen needles, infusion sets, glucose monitors) may see knock-on demand changes.",
    sourceUrl:
      "https://www.drugshortagescanada.ca/shortage/example-insulin-glargine",
    categories: ["diabetes-management-devices"],
    confidence: 0.9,
    reasoning:
      "Drug shortage affects co-prescribed device categories (insulin delivery and glucose monitoring) that match Acme MedDev's catalog. Urgency CRITICAL because customer demand can shift within hours of public posting and Acme distributes the relevant consumables.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/10/health-canada-shortages_82042_03180009.json",
    auditVersionId: "Vk3m2NhJ5RtSp7qPdYxA",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82045",
    externalId: "ME-82045",
    title: "Acetaminophen — hepatotoxicity adverse event",
    source: "MedEffect",
    urgency: "LOW",
    classification: "NOT_RELEVANT",
    classifiedAt: "2026-05-10T01:05:00Z",
    ago: "6h ago",
    body: "A MedEffect adverse event report describes a case of acute hepatic injury in an adult patient following an extended-release acetaminophen regimen at therapeutic doses. The report includes no implicated devices or implants. Health Canada has not indicated any device-related action.",
    sourceUrl:
      "https://canada-medeffect.example.gc.ca/event/example-acetaminophen-hepatotoxicity",
    categories: [],
    confidence: 0.0,
    reasoning:
      "The signal pertains to pharmacovigilance, not device safety. No medical device or implant is mentioned in the report and no related device categories appear in Acme MedDev's catalog. Marked NOT_RELEVANT with confidence 0.0; no obligations attach.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/10/health-canada-medeffect_82045_01050015.json",
    auditVersionId: "Vq8r4SbT1MnGd6vWcYzU",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82048",
    externalId: "RA-82048",
    title: "Surgical mesh defect — voluntary recall",
    source: "Health Canada Recalls",
    urgency: "MEDIUM",
    classification: "NEEDS_REVIEW",
    classifiedAt: "2026-05-09T23:50:00Z",
    ago: "8h ago",
    body: "Manufacturer-initiated voluntary recall of a soft-tissue surgical mesh after intermittent batch-level failures in tensile strength testing. Affected lots have not been associated with adverse patient outcomes. Distributors are asked to quarantine inventory pending replacement.",
    sourceUrl:
      "https://recalls-rappels.canada.ca/en/alert-recall/example-surgical-mesh-recall",
    categories: ["surgical-implants"],
    confidence: 0.62,
    reasoning:
      "Voluntary Class II-style recall. Category 'surgical-implants' partially overlaps with Acme MedDev's catalog but the specific mesh product is not on Acme's current order list. Marked NEEDS_REVIEW with confidence 0.62 so a compliance officer can verify before clearing or escalating.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/09/health-canada-recalls_82048_23500041.json",
    auditVersionId: "Vj5n8PwL3CkHb2tFdRxE",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82050",
    externalId: "RA-82050",
    title: "Infusion pump firmware vulnerability advisory",
    source: "Health Canada Recalls",
    urgency: "HIGH",
    classification: "RELEVANT",
    classifiedAt: "2026-05-09T21:14:00Z",
    ago: "11h ago",
    body: "A field safety notice has been issued for a family of infusion pumps after a security researcher disclosed a remote firmware modification vulnerability. The manufacturer has released a patched firmware and is coordinating distributor-led updates at hospital sites.",
    sourceUrl:
      "https://recalls-rappels.canada.ca/en/alert-recall/example-infusion-pump-fsn",
    categories: ["infusion-devices"],
    confidence: 0.88,
    reasoning:
      "Field safety notice for an active medical device in Acme MedDev's catalog (infusion-devices). Cyber-physical vulnerability with documented patch. Urgency HIGH rather than CRITICAL because no exploitation has been observed and a remediation path exists.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/09/health-canada-recalls_82050_21140019.json",
    auditVersionId: "Vd2g6QmF4TyKn8sVcXzB",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82051",
    externalId: "DS-82051",
    title: "Iodinated contrast media — supply constraint update",
    source: "Health Canada Shortages",
    urgency: "MEDIUM",
    classification: "NEEDS_REVIEW",
    classifiedAt: "2026-05-09T18:42:00Z",
    ago: "13h ago",
    body: "Updated supply estimates for iodinated contrast media indicate continued constraint through Q3 2026. The notice affects diagnostic imaging workflows and may have downstream impact on contrast-injection consumables and devices.",
    sourceUrl:
      "https://www.drugshortagescanada.ca/shortage/example-iodinated-contrast",
    categories: ["imaging-consumables"],
    confidence: 0.55,
    reasoning:
      "Drug shortage with indirect device implications. Acme MedDev distributes contrast-injection consumables but not the contrast media itself. Marked NEEDS_REVIEW because the downstream effect on Acme's order book is genuine but not immediate.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/09/health-canada-shortages_82051_18420027.json",
    auditVersionId: "Vh9c1LpR7BvJm4xQdWyT",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82053",
    externalId: "ME-82053",
    title: "Ibuprofen — gastrointestinal bleeding cluster",
    source: "MedEffect",
    urgency: "LOW",
    classification: "NOT_RELEVANT",
    classifiedAt: "2026-05-09T15:30:00Z",
    ago: "16h ago",
    body: "Cluster of MedEffect adverse event reports describing upper gastrointestinal bleeding in elderly patients on long-term ibuprofen. No implicated devices.",
    sourceUrl:
      "https://canada-medeffect.example.gc.ca/event/example-ibuprofen-gi-cluster",
    categories: [],
    confidence: 0.05,
    reasoning:
      "Pharmacovigilance signal. No medical devices implicated and no overlap with Acme MedDev's catalog. NOT_RELEVANT with very low confidence-of-relevance score.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/09/health-canada-medeffect_82053_15300003.json",
    auditVersionId: "Vw3t8DnB5GfMc6yRkPxL",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
  {
    id: "rec-82055",
    externalId: "RA-82055",
    title: "Pulse oximeter — pigmentation accuracy advisory",
    source: "Health Canada Recalls",
    urgency: "MEDIUM",
    classification: "RELEVANT",
    classifiedAt: "2026-05-09T11:22:00Z",
    ago: "20h ago",
    body: "An advisory has been issued for a family of pulse oximeters following a published study showing reduced accuracy in patients with darker skin pigmentation. The manufacturer has issued updated guidance and is conducting a field assessment.",
    sourceUrl:
      "https://recalls-rappels.canada.ca/en/alert-recall/example-pulse-ox-advisory",
    categories: ["patient-monitoring"],
    confidence: 0.81,
    reasoning:
      "Field safety advisory for a monitoring device in Acme MedDev's catalog. The signal is RELEVANT but urgency is MEDIUM because no recall has been issued and the clinical mitigation is updated usage guidance rather than product removal.",
    auditPath:
      "s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-acme-meddev/2026/05/09/health-canada-recalls_82055_11220011.json",
    auditVersionId: "Vy4k7VtN2HsLp9bFcXrA",
    kmsKeyAlias: "alias/regops-sentinel-dev-1a8df723",
  },
]

export function getAlertById(id: string): Alert | undefined {
  return alerts.find((a) => a.id === id)
}

export function getAlerts(): Alert[] {
  return alerts
}
