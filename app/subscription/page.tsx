import { Suspense } from "react";
import Link from "next/link";
import { redirect } from "next/navigation";
import { Check } from "lucide-react";
import { createClient } from "@/lib/supabase/server";
import { launchPrices, naira, type PlanPrices } from "@/lib/saas/pricing";
import { plans, type SubscriptionAccess } from "@/lib/saas/types";
export default function SubscriptionPage({ searchParams }: { searchParams: Promise<{ organization?: string }> }) {
  return <Suspense fallback={<main className="setup-page"><p role="status">Loading subscription…</p></main>}><SubscriptionEntry searchParams={searchParams}/></Suspense>;
}
async function SubscriptionEntry({ searchParams }: { searchParams: Promise<{ organization?: string }> }) {
  const db = await createClient(); const requested = (await searchParams).organization;
  const { data: { user } } = await db.auth.getUser(); if (!user) redirect("/auth/login");
  let query = db.from("organization_memberships").select("organization_id,role,organizations(name)").eq("user_id",user.id).eq("active",true).order("created_at");
  if (requested) query = query.eq("organization_id",requested);
  const { data: memberships, error: membershipError } = await query.limit(1);
  if (membershipError || !memberships?.length) redirect("/");
  const membership = memberships[0]; const org = membership.organization_id;
  const [{ data: raw, error }, { count: propertyCount }, { count: staffCount }, { count: invitationCount }, { data: catalog }] = await Promise.all([
    db.rpc("get_subscription_access",{p_organization_id:org}), db.from("properties").select("id",{count:"exact",head:true}).eq("organization_id",org),
    db.from("organization_memberships").select("user_id",{count:"exact",head:true}).eq("organization_id",org).eq("active",true),
    membership.role === "owner" ? db.from("team_invitations").select("id",{count:"exact",head:true}).eq("organization_id",org).is("accepted_at",null).gt("expires_at",new Date().toISOString()) : Promise.resolve({count:null}),
    db.from("saas_plan_prices").select("plan_code,monthly_price_kobo"),
  ]);
  const prices: PlanPrices = { ...launchPrices };
  for (const row of catalog ?? []) if (row.plan_code in prices) prices[row.plan_code as keyof PlanPrices] = Number(row.monthly_price_kobo);
  const access = raw as SubscriptionAccess | null;
  const cutoff = access?.status === "trialing" ? access.trial_ends_at : access?.current_period_end;
  const organization = Array.isArray(membership.organizations) ? membership.organizations[0] : membership.organizations;
  return <div className="platform-shell"><header className="platform-topbar"><Link className="platform-brand" href="/"><span className="brand-mark">C</span><strong>Coastline</strong></Link><Link className="button" href="/">Return to hotel</Link></header><main className="platform-content"><div className="page-heading"><div><div className="eyebrow">{organization?.name ?? "YOUR HOTEL"}</div><h1>Subscription & plans</h1><p>Choose the tools and capacity your hotel business needs.</p></div></div>{error || !access ? <section className="panel subscription-current"><h2>Subscription unavailable</h2><p>The SaaS database update must be installed to view your plan.</p></section> : <section className="panel subscription-current"><div><span className="eyebrow">CURRENT PLAN</span><h2>{access.plan_name ?? "Unassigned"}{access.grandfathered && <span className="status-pill green-pill">Existing pilot</span>}</h2><p>{access.grandfathered ? "Your existing hotel keeps unrestricted access during the pilot." : access.access === "read_only" ? "Your subscription is read-only. Your stored records and available exports are retained. Contact platform support to renew." : access.access === "grace" ? "Your subscription has entered a 7-day grace period. Contact platform support to renew." : access.status === "trialing" ? "Your 14-day Business trial includes the tools for one property." : "Your hotel subscription is active."}</p>{!access.grandfathered && access.monthly_fee_kobo != null && <p><strong>{naira(Number(access.monthly_fee_kobo))} / month</strong> · agreed subscription fee</p>}{cutoff && <small>{access.status === "trialing" ? "Trial ends" : "Billing period ends"} {new Date(cutoff).toLocaleDateString("en-NG",{day:"numeric",month:"short",year:"numeric",timeZone:"Africa/Lagos"})}</small>}</div><div className="subscription-usage"><span><b>{propertyCount ?? 0}</b> / {access.property_limit ?? "unlimited"} accessible properties</span><span><b>{staffCount ?? 0}</b> / {access.staff_limit ?? "unlimited"} active staff</span>{invitationCount != null && <small>{invitationCount} pending invitations also reserve staff capacity.</small>}</div></section>}<div className="platform-plan-grid">{plans.map(plan => <article className={`panel subscription-plan ${access?.plan_code === plan.code ? "subscription-plan-current" : ""}`} key={plan.code}><div className="card-heading"><div><strong>{plan.name}</strong><small>{plan.capacity}</small></div>{access?.plan_code === plan.code && <span className="status-pill green-pill">Current</span>}</div><div className="platform-plan-price">{plan.code === "group" && <small>From </small>}{naira(prices[plan.code])}<small> / month</small></div><p>{plan.description}{plan.code === "group" ? " Custom quotes are available for larger hotel groups." : ""}</p><ul>{plan.features.map(feature => <li key={feature}><Check size={16}/>{feature}</li>)}</ul></article>)}</div><section className="panel subscription-help"><h2>Change or renew your plan</h2><p>{membership.role === "owner" ? "Contact your Coastline platform administrator to arrange a plan change or renewal. Plan changes are applied after your subscription is confirmed." : "Ask your hotel owner to contact Coastline about a plan change or renewal."}</p><p>Starter is ₦15,000/month, Business is ₦35,000/month and Group starts at ₦75,000/month. Your administrator confirms your agreed fee. Online payment collection is not connected yet.</p></section></main></div>;
}
