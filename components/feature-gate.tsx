import Link from "next/link";
import { LockKeyhole } from "lucide-react";
import { featureLabels, hasFeature, type Feature, type SubscriptionAccess } from "@/lib/saas/types";
export function FeatureGate({ subscription, feature, organizationId, children }: { subscription?: SubscriptionAccess; feature: Feature; organizationId: string; children: React.ReactNode }) {
  if (hasFeature(subscription, feature)) return children;
  return <section className="panel plan-gate"><span className="plan-gate-icon"><LockKeyhole size={23}/></span><h2>{featureLabels[feature]}</h2><p>{subscription?.access === "read_only" ? "Your hotel subscription is read-only. Review the plan to restore access." : feature === "multi_property" ? "This feature is included in the Group plan." : "This feature is included in the Business and Group plans."}</p><Link className="button button-primary" href={`/subscription?organization=${encodeURIComponent(organizationId)}`}>View subscription plans</Link><small>Your existing hotel records are retained.</small></section>;
}
