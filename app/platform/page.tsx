import { Suspense } from "react";
import Link from "next/link";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { PlatformDashboard } from "@/components/platform-dashboard";
import type { PlatformOverview, PlatformRevenueReport } from "@/lib/saas/types";
export default function PlatformPage() {
  return <Suspense fallback={<main className="setup-page"><p role="status">Loading platform overview…</p></main>}><PlatformEntry/></Suspense>;
}
async function PlatformEntry() {
  const db = await createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) redirect("/auth/login?next=/platform");
  const { data: admin, error } = await db.rpc("is_platform_admin");
  if (error || !admin) return <main className="setup-page"><section className="setup-card"><div className="eyebrow">Coastline platform</div><h1>{error ? "Platform dashboard unavailable" : "Platform administrator access required"}</h1><p>{error ? "The platform database update must be installed before this dashboard is available." : "This dashboard is restricted to the platform administrator account."}</p><Link className="button" href="/">Return to your hotel</Link></section></main>;
  const [{ data, error: overviewError }, { data: memberships }, normalRevenue, testRevenue] = await Promise.all([
    db.rpc("get_platform_overview"), db.from("organization_memberships").select("organization_id").eq("user_id",user.id).eq("active",true).limit(1),
    db.rpc("get_platform_revenue", { p_include_tests: false }), db.rpc("get_platform_revenue", { p_include_tests: true }),
  ]);
  if (overviewError) return <main className="setup-page"><section className="setup-card"><h1>Platform data could not be loaded</h1><p>Refresh this page to try again.</p><Link className="button" href="/platform">Refresh</Link></section></main>;
  return <PlatformDashboard overview={data as PlatformOverview} hasHotelWorkspace={Boolean(memberships?.length)} adminEmail={user.email} revenue={normalRevenue.error || testRevenue.error ? null : { standard: normalRevenue.data as PlatformRevenueReport, includingTests: testRevenue.data as PlatformRevenueReport }}/>;
}
