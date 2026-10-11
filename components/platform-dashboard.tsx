"use client";

import { useActionState, useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ArrowRight, ArrowUpCircle, Building2, CalendarDays, Check, CircleDollarSign, CreditCard, LayoutDashboard, Layers3, Menu, RefreshCw, Search, ShieldCheck, Users, X } from "lucide-react";
import { PlatformRevenue } from "@/components/platform-revenue";
import { launchPrices, naira, type PlanPrices } from "@/lib/saas/pricing";
import type { PlatformRevenue as PlatformRevenueData } from "@/lib/saas/types";
import { LogoutButton } from "@/components/logout-button";
import { updateSubscription, type SubscriptionActionState } from "@/app/platform/actions";
import { plans, type PlatformHotel, type PlatformOverview } from "@/lib/saas/types";
import { availableUpgradePlans, billingDateInput } from "@/lib/saas/upgrades";

const money = (kobo: number) => `₦${new Intl.NumberFormat("en-NG").format(kobo / 100)}`;
const date = (value: string | null | undefined) => value ? new Date(value).toLocaleDateString("en-NG", { day: "numeric", month: "short", year: "numeric", timeZone: "Africa/Lagos" }) : "—";
const views = [
  { id: "overview", label: "Overview", title: "Platform overview", description: "Monitor hotel onboarding, subscriptions and product activity.", icon: LayoutDashboard },
  { id: "hotels", label: "Hotels", title: "Hotel directory", description: "View your hotel businesses, owners and onboarding progress.", icon: Building2 },
  { id: "subscriptions", label: "Subscriptions", title: "Subscriptions", description: "Manage customer plans, subscription status and renewal dates.", icon: CreditCard },
  { id: "revenue", label: "Revenue", title: "Subscription revenue", description: "Track subscription income, collections and refunds across your hotel customers.", icon: CircleDollarSign },
  { id: "plans", label: "Plans & features", title: "Plans & features", description: "See the features and account limits included in each tier.", icon: Layers3 },
] as const;
type PlatformView = typeof views[number]["id"];

export function PlatformDashboard({ overview, hasHotelWorkspace, adminEmail, revenue }: { overview: PlatformOverview; hasHotelWorkspace: boolean; adminEmail?: string; revenue?: PlatformRevenueData | null }) {
  const router = useRouter();
  const [view, setView] = useState<PlatformView>("overview");
  const [menuOpen, setMenuOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [filter, setFilter] = useState("all");
  const [includeTests, setIncludeTests] = useState(false);
  const [selected, setSelected] = useState<{ hotel: PlatformHotel; mode: "manage" | "upgrade" }>();
  const menuDialog = useRef<HTMLDialogElement>(null);
  const closeEditor = useCallback(() => setSelected(undefined), []);
  const currentView = views.find(item => item.id === view)!;
  const revenueReport = revenue ? includeTests ? revenue.includingTests : revenue.standard : null;
  const prices = revenueReport?.prices ?? launchPrices;
  const hotels = overview.hotels.filter(hotel => includeTests || !hotel.is_test);
  const now = Date.parse(overview.as_of);
  const active = hotels.filter(hotel => hotel.last_activity_at && Date.parse(hotel.last_activity_at) >= now - 30 * 86400000);
  const paying = hotels.filter(hotel => !hotel.subscription.grandfathered && hotel.subscription.status === "active" && hotel.subscription.access === "full" && Number(hotel.monthly_fee_kobo) > 0);
  const trials = hotels.filter(hotel => hotel.subscription.status === "trialing" && hotel.subscription.access === "full");
  const month = new Date(now).toLocaleDateString("en-CA", { year: "numeric", month: "2-digit", timeZone: "Africa/Lagos" });
  const createdThisMonth = hotels.filter(hotel => new Date(hotel.created_at).toLocaleDateString("en-CA", { year: "numeric", month: "2-digit", timeZone: "Africa/Lagos" }) === month).length;
  const attention = hotels.filter(hotel => hotel.subscription.access !== "full").length;
  const rows = hotels.filter(hotel => `${hotel.name} ${hotel.owner_email ?? ""}`.toLowerCase().includes(query.toLowerCase()))
    .filter(hotel => filter === "all" || (filter === "trial" ? hotel.subscription.status === "trialing" : filter === "attention" ? hotel.subscription.access !== "full" || !hotel.onboarded : filter === "pilot" ? hotel.subscription.grandfathered : paying.includes(hotel)));

  useEffect(() => {
    if (menuOpen) menuDialog.current?.showModal();
    else menuDialog.current?.close();
  }, [menuOpen]);

  function navigate(next: PlatformView) {
    setView(next);
    setMenuOpen(false);
    setQuery("");
    setFilter("all");
  }
  function navigation() {
    return <nav className="platform-nav" aria-label="Platform navigation">
      <div className="nav-label">PLATFORM MANAGEMENT</div>
      {views.map(({ id, label, icon: Icon }) => <button key={id} className={`nav-item ${view === id ? "active" : ""}`} aria-current={view === id ? "page" : undefined} onClick={() => navigate(id)}><Icon size={18}/>{label}{id === "hotels" && <span className="platform-nav-count">{hotels.length}</span>}{id === "subscriptions" && attention > 0 && <span className="platform-nav-count">{attention}</span>}</button>)}
      {hasHotelWorkspace && <><div className="nav-label platform-workspace-label">YOUR WORKSPACE</div><Link className="nav-item" href="/"><ArrowRight size={18}/>Hotel workspace</Link></>}
    </nav>;
  }
  const brand = <Link className="platform-brand" href="/platform"><span className="brand-mark">C</span><span><strong>Coastline</strong><small>PLATFORM ADMINISTRATION</small></span></Link>;

  return <div className="platform-shell platform-admin-shell">
    <aside className="platform-sidebar">
      {brand}{navigation()}
      <div className="platform-sidebar-footer"><span className="platform-admin-icon"><ShieldCheck size={19}/></span><div><strong>Platform administrator</strong><small>{adminEmail ?? "Manage your SaaS business"}</small></div></div>
    </aside>
    <dialog ref={menuDialog} className="platform-mobile-menu" aria-label="Platform menu" onCancel={() => setMenuOpen(false)}>
      <div className="platform-mobile-menu-heading">{brand}<button className="icon-button" aria-label="Close platform menu" onClick={() => setMenuOpen(false)}><X size={19}/></button></div>
      {navigation()}
    </dialog>
    <div className="platform-main">
      <header className="platform-topbar"><div className="platform-topbar-location"><button className="icon-button platform-menu-button" aria-label="Open platform menu" aria-expanded={menuOpen} onClick={() => setMenuOpen(true)}><Menu size={20}/></button><span>Platform <span className="platform-breadcrumb-divider">/</span> <strong>{currentView.label}</strong></span></div><LogoutButton/></header>
      <main className="platform-content">
        <div className="page-heading"><div><div className="eyebrow">YOUR SAAS BUSINESS</div><h1>{currentView.title}</h1><p>{currentView.description}</p></div><button className="button" onClick={() => router.refresh()}><RefreshCw size={15}/>Refresh</button></div>
        {view === "overview" && <>
          <div className="platform-summary"><Stat label="Hotel businesses onboarded" value={String(hotels.filter(hotel => hotel.onboarded).length)} note={`${hotels.length} customer organizations · ${hotels.reduce((sum, hotel) => sum + Number(hotel.properties), 0)} properties`} icon={Building2}/><Stat label="Active customers" value={String(active.length)} note="Operational activity in the last 30 days" icon={Users}/><Stat label="Paying customers" value={String(paying.length)} note={`${trials.length} active trials · pilot accounts excluded`} icon={CalendarDays}/><Stat label="Monthly recurring revenue" value={money(paying.reduce((sum, hotel) => sum + Number(hotel.monthly_fee_kobo), 0))} note="Configured monthly subscriptions · not collected payments" icon={CircleDollarSign}/></div>
          <div className="platform-pulse"><span><b>{createdThisMonth}</b> new customers this month</span><span><b>{hotels.filter(hotel => !hotel.onboarded).length}</b> incomplete setups</span><span><b>{attention}</b> subscriptions need attention</span><span><b>{hotels.reduce((sum, hotel) => sum + Number(hotel.rooms), 0)}</b> active rooms managed</span></div>
        </>}
        {view !== "plans" && view !== "revenue" && <section className="panel platform-directory">
          <div className="card-heading"><div><strong>{view === "subscriptions" ? "Customer subscriptions" : "Hotel directory"}</strong><small>{view === "subscriptions" ? "Upgrade a plan, activate a trial or manage an existing subscription." : "Onboarded means rooms are configured and an active owner is present."}</small></div><span className="status-pill green-pill">{hotels.length} {hotels.length === 1 ? "customer" : "customers"}</span></div>
          <div className="page-tools"><label className="search-box"><Search size={16}/><input aria-label="Search hotels" placeholder="Search hotel or owner email" value={query} onChange={event => setQuery(event.target.value)}/></label><select className="select-control" aria-label="Filter subscriptions" value={filter} onChange={event => setFilter(event.target.value)}><option value="all">All customers</option><option value="trial">Trials</option><option value="paying">Paying</option><option value="attention">Needs attention</option><option value="pilot">Existing pilots</option></select><label className="platform-test-toggle"><input type="checkbox" checked={includeTests} onChange={event => setIncludeTests(event.target.checked)}/>Include test workspaces</label></div>
          <div className="table-wrap platform-desktop-directory"><table className="platform-table"><thead><tr><th>Hotel business</th><th>Plan & status</th>{view !== "subscriptions" && <><th>Properties / rooms</th><th>Staff</th><th>Joined</th><th>Last activity</th></>}<th>Monthly fee</th><th>Renewal / trial end</th><th><span className="sr-only">Actions</span></th></tr></thead><tbody>{rows.map(hotel => <tr key={hotel.id}><td><strong>{hotel.name}</strong><small>{hotel.owner_email ?? "Owner contact unavailable"}</small>{hotel.is_test && <span className="status-pill amber-pill">Test workspace</span>}</td><td><strong>{hotel.subscription.plan_name}</strong><SubscriptionStatus hotel={hotel}/></td>{view !== "subscriptions" && <><td>{hotel.properties} / {hotel.rooms}</td><td>{hotel.staff}</td><td>{date(hotel.created_at)}</td><td>{date(hotel.last_activity_at)}</td></>}<td>{hotel.subscription.grandfathered ? "Pilot access" : hotel.monthly_fee_kobo == null ? "Not agreed" : naira(Number(hotel.monthly_fee_kobo))}</td><td>{date(hotel.subscription.status === "trialing" ? hotel.subscription.trial_ends_at : hotel.subscription.current_period_end)}</td><td><div className="platform-subscription-buttons"><UpgradeButton hotel={hotel} open={() => setSelected({ hotel, mode: "upgrade" })}/><button className="button platform-manage-button" onClick={() => setSelected({ hotel, mode: "manage" })}>Manage<ArrowRight size={14}/></button></div></td></tr>)}</tbody></table></div>
          <div className="platform-mobile-directory">{rows.map(hotel => <article className="platform-hotel-card" key={hotel.id}><div className="platform-hotel-card-heading"><div><strong>{hotel.name}</strong><small>{hotel.owner_email ?? "Owner contact unavailable"}</small></div><SubscriptionStatus hotel={hotel}/></div><dl><div><dt>Plan</dt><dd>{hotel.subscription.plan_name}</dd></div><div><dt>Monthly fee</dt><dd>{hotel.subscription.grandfathered ? "Pilot access" : hotel.monthly_fee_kobo == null ? "Not agreed" : naira(Number(hotel.monthly_fee_kobo))}</dd></div><div><dt>Renewal / trial end</dt><dd>{date(hotel.subscription.status === "trialing" ? hotel.subscription.trial_ends_at : hotel.subscription.current_period_end)}</dd></div><div><dt>Properties / rooms</dt><dd>{hotel.properties} / {hotel.rooms}</dd></div><div><dt>Staff accounts</dt><dd>{hotel.staff}</dd></div></dl>{hotel.is_test && <p className="status-pill amber-pill">Test workspace</p>}<div className="platform-subscription-buttons"><UpgradeButton hotel={hotel} open={() => setSelected({ hotel, mode: "upgrade" })}/><button className="button" onClick={() => setSelected({ hotel, mode: "manage" })}>Manage subscription<ArrowRight size={14}/></button></div></article>)}</div>
          {!rows.length && <p className="empty-state">No hotels match these filters.</p>}
        </section>}
        {view === "revenue" && <PlatformRevenue report={revenueReport} hotels={hotels} includeTests={includeTests} setIncludeTests={setIncludeTests}/>}
        {view === "plans" && <section className="platform-plan-grid">{plans.map(plan => <article className="panel" key={plan.code}><div className="card-heading"><div><strong>{plan.name}</strong><small>{plan.capacity}</small></div></div><div className="platform-plan-price">{plan.code === "group" && <small>From </small>}{naira(prices[plan.code])}<small> / month</small></div>{plan.code === "group" && <p className="platform-plan-quote">Custom quotes for larger hotel groups.</p>}<ul>{plan.features.map(feature => <li key={feature}><Check size={14}/>{feature}</li>)}</ul></article>)}</section>}
        <p className="platform-footnote">Activity reflects recorded hotel operations, not just sign-ins. Online payment collection and automatic billing are not connected. Record received subscription payments in Revenue. Refreshed {date(overview.as_of)}.</p>
      </main>
    </div>
    {selected && (selected.mode === "upgrade" ? <SubscriptionUpgrade key={selected.hotel.id} hotel={selected.hotel} close={closeEditor} asOf={overview.as_of} prices={prices}/> : <SubscriptionEditor key={selected.hotel.id} hotel={selected.hotel} close={closeEditor} prices={prices}/>)}
  </div>;
}

function SubscriptionStatus({ hotel }: { hotel: PlatformHotel }) {
  return <span className={`status-pill ${hotel.subscription.access === "full" ? "green-pill" : "amber-pill"}`}>{hotel.subscription.grandfathered ? "Pilot access" : hotel.subscription.access === "grace" ? "Grace period" : hotel.subscription.access === "read_only" ? "Read-only" : (hotel.subscription.status ?? "Not configured").replaceAll("_", " ")}</span>;
}
function Stat({ label, value, note, icon: Icon }: { label: string; value: string; note: string; icon: typeof Building2 }) {
  return <article className="metric-card"><div className="metric-label">{label}<Icon size={18}/></div><strong className="metric-value">{value}</strong><small className="metric-foot">{note}</small></article>;
}
function SubscriptionEditor({ hotel, close, prices }: { hotel: PlatformHotel; close: () => void; prices: PlanPrices }) {
  const [monthlyFee, setMonthlyFee] = useState(hotel.monthly_fee_kobo == null ? "" : String(Number(hotel.monthly_fee_kobo) / 100));
  const dialog = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const previousOverflow = document.body.style.overflow;
    const panel = dialog.current;
    panel?.showModal();
    panel?.querySelector<HTMLElement>("select")?.focus();
    document.body.style.overflow = "hidden";
    return () => { panel?.close(); document.body.style.overflow = previousOverflow; previous?.focus(); };
  }, []);
  const [state, action, pending] = useActionState(updateSubscription, {} as SubscriptionActionState);
  return <dialog ref={dialog} className="platform-subscription-modal" aria-labelledby="subscription-editor-title" aria-describedby="subscription-editor-description" onCancel={event => { event.preventDefault(); if (!pending) close(); }}>
    <header className="platform-editor-header"><div><div className="eyebrow">SUBSCRIPTION MANAGEMENT</div><h2 id="subscription-editor-title">{hotel.name}</h2><p id="subscription-editor-description">Changes apply to all properties in this customer’s organization.</p></div><button className="icon-button" disabled={pending} onClick={close} aria-label="Close subscription editor"><X size={20}/></button></header>
    <form action={action} className="platform-subscription-form">
      <div className="platform-editor-fields"><input type="hidden" name="organization_id" value={hotel.id}/>
        {hotel.subscription.grandfathered && <p className="platform-editor-note">Saving replaces this hotel’s existing unrestricted pilot access with the selected plan.</p>}
        <div className="platform-editor-row"><label>Plan<select name="plan" defaultValue={hotel.subscription.plan_code ?? "business"} onChange={event => { const code = event.target.value as keyof PlanPrices; setMonthlyFee(String(prices[code] / 100)); }}>{plans.map(plan => <option value={plan.code} key={plan.code}>{plan.name}</option>)}</select></label><label>Status<select name="status" defaultValue={hotel.subscription.status}><option value="trialing">Trial</option><option value="active">Active</option><option value="past_due">Past due</option><option value="expired">Expired</option><option value="cancelled">Cancelled</option></select></label></div>
        <div className="platform-editor-row"><label>Trial / billing end date<input type="date" name="period_end" defaultValue={billingDateInput(hotel.subscription.status === "trialing" ? hotel.subscription.trial_ends_at : hotel.subscription.current_period_end)}/></label><label>Monthly subscription fee (₦)<input type="number" name="monthly_fee" min="0" step="0.01" placeholder="Not set" value={monthlyFee} onChange={event => setMonthlyFee(event.target.value)}/></label></div>
        <p className="platform-field-help">Prices follow the selected tier. You can enter an agreed custom fee. Setting a fee does not collect payment.</p>
        <label>Reason for change<textarea name="reason" minLength={5} maxLength={500} required rows={3} placeholder="Explain why you’re updating this subscription"/></label>
        <label className="platform-editor-checkbox"><input type="checkbox" name="is_test" defaultChecked={hotel.is_test}/><span>Test workspace<small>Exclude this customer from default platform totals.</small></span></label>
        {state.error && <p className="form-error" role="alert">{state.error}</p>}{state.success && <p className="folio-success" role="status">Subscription updated. Close this window to review the refreshed directory.</p>}
      </div>
      <footer className="platform-editor-actions"><button type="button" className="button" disabled={pending} onClick={close}>{state.success ? "Close" : "Cancel"}</button><button type="submit" className="button button-primary" disabled={pending}>{pending ? "Saving…" : "Save subscription"}</button></footer>
    </form>
  </dialog>;
}


function UpgradeButton({ hotel, open }: { hotel: PlatformHotel; open: () => void }) {
  if (!availableUpgradePlans(hotel.subscription).length) return null;
  return <button className="button button-primary" onClick={open}><ArrowUpCircle size={15}/>{hotel.subscription.grandfathered || hotel.subscription.status === "trialing" ? "Activate plan" : "Upgrade plan"}</button>;
}

function SubscriptionUpgrade({ hotel, close, asOf, prices }: { hotel: PlatformHotel; close: () => void; asOf: string; prices: PlanPrices }) {
  const dialog = useRef<HTMLDialogElement>(null);
  const upgradePlans = availableUpgradePlans(hotel.subscription);
  const [planCode, setPlanCode] = useState<string>(upgradePlans[0]?.code ?? "group");
  const targetPlan = plans.find(plan => plan.code === planCode)!;
  const activation = hotel.subscription.grandfathered || hotel.subscription.status === "trialing";
  const [monthlyFee, setMonthlyFee] = useState(String((activation && hotel.subscription.plan_code === targetPlan.code && hotel.monthly_fee_kobo != null ? Number(hotel.monthly_fee_kobo) : prices[targetPlan.code]) / 100));
  const [state, action, pending] = useActionState(updateSubscription, {} as SubscriptionActionState);
  const successfulPlan = plans.find(plan => plan.name === state.planName) ?? targetPlan;
  const currentEnd = hotel.subscription.current_period_end;
  const initialEnd = currentEnd && Date.parse(currentEnd) > Date.parse(asOf) ? billingDateInput(currentEnd) : "";
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const previousOverflow = document.body.style.overflow;
    const panel = dialog.current;
    panel?.showModal();
    panel?.querySelector<HTMLElement>("input[type=radio]")?.focus();
    document.body.style.overflow = "hidden";
    return () => { panel?.close(); document.body.style.overflow = previousOverflow; previous?.focus(); };
  }, []);
  return <dialog ref={dialog} className="platform-subscription-modal" aria-labelledby="subscription-upgrade-title" aria-describedby="subscription-upgrade-description" onCancel={event => { event.preventDefault(); if (!pending) close(); }}>
    <header className="platform-editor-header"><div><div className="eyebrow">{state.success ? "PLAN UPDATED" : "ADMIN PLAN CHANGE"}</div><h2 id="subscription-upgrade-title">{state.success ? `${successfulPlan.name} is now active` : activation ? "Activate subscription" : "Upgrade subscription"}</h2><p id="subscription-upgrade-description">{hotel.name} · {hotel.owner_email ?? "Hotel customer"}</p></div><button className="icon-button" disabled={pending} onClick={close} aria-label="Close plan upgrade"><X size={20}/></button></header>
    {state.success ? <><div className="platform-editor-fields platform-upgrade-success"><span className="platform-upgrade-success-icon"><Check size={24}/></span><p role="status">{hotel.name} now has access to the {successfulPlan.name} plan. The change has been saved and recorded in the subscription history.</p><ul>{successfulPlan.features.map(feature => <li key={feature}><Check size={15}/>{feature}</li>)}</ul></div><footer className="platform-editor-actions"><button autoFocus className="button button-primary" onClick={close}>Done</button></footer></> : <form action={action} className="platform-subscription-form">
      <input type="hidden" name="organization_id" value={hotel.id}/><input type="hidden" name="intent" value="upgrade"/>
      <div className="platform-editor-fields"><div className="platform-upgrade-current"><span>Current plan</span><strong>{hotel.subscription.plan_name ?? "Unassigned"}</strong><SubscriptionStatus hotel={hotel}/></div>
        <fieldset className="platform-upgrade-plans" disabled={pending}><legend>{activation ? "Choose the plan to activate" : "Choose an upgrade"}</legend>{upgradePlans.map(plan => <label className={`platform-upgrade-option ${planCode === plan.code ? "selected" : ""}`} key={plan.code}><input type="radio" name="plan" value={plan.code} checked={planCode === plan.code} onChange={() => { setPlanCode(plan.code); setMonthlyFee(String(prices[plan.code] / 100)); }} required/><span><strong>{plan.name}</strong><small>{plan.capacity} · {plan.code === "group" ? "from " : ""}{naira(prices[plan.code])}/month</small><span className="platform-upgrade-description">{plan.description}</span></span></label>)}</fieldset>
        <div className="platform-upgrade-benefits"><strong>Included in {targetPlan.name}</strong><ul>{targetPlan.features.map(feature => <li key={feature}><Check size={14}/>{feature}</li>)}</ul></div>
        {hotel.subscription.grandfathered && <p className="platform-editor-note">Activating this plan replaces unrestricted pilot access. The selected plan’s features and limits will apply to every property in this hotel business.</p>}
        <fieldset className="platform-upgrade-billing" disabled={pending}><div className="platform-editor-row"><label>Billing end date (optional)<input type="date" name="period_end" min={billingDateInput(asOf)} defaultValue={initialEnd}/></label><label>Monthly subscription fee (₦)<input type="number" name="monthly_fee" min="0" step="0.01" placeholder="Not set" value={monthlyFee} onChange={event => setMonthlyFee(event.target.value)}/></label></div><p className="platform-field-help">Access starts immediately. Without an end date, the plan stays active until you change it. The fee records agreed pricing; it does not collect payment.</p><label>Reason for change<textarea name="reason" minLength={5} maxLength={500} required rows={2} placeholder="For example, the customer requested more features"/></label></fieldset>
        {state.error && <p className="form-error" role="alert">{state.error}</p>}
      </div><footer className="platform-editor-actions"><button type="button" className="button" disabled={pending} onClick={close}>Cancel</button><button type="submit" className="button button-primary" disabled={pending}>{pending ? "Saving…" : `${activation ? "Activate" : "Upgrade to"} ${targetPlan.name}`}</button></footer>
    </form>}
  </dialog>;
}
