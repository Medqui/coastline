import { Suspense } from "react";
import Link from "next/link";
import { redirect } from "next/navigation";
import { hasEnvVars } from "@/lib/utils";
import { createClient } from "@/lib/supabase/server";
import { HotelSetupForm } from "@/components/hotel-setup-form";

export default function OnboardingPage() {
  return <Suspense fallback={<main className="setup-page"><p role="status">Loading hotel setup…</p></main>}><OnboardingContent/></Suspense>;
}

async function OnboardingContent() {
  if (!hasEnvVars) {
    return <main className="setup-page"><section className="setup-card"><div className="brand-mark setup-logo">C</div><div className="eyebrow">FIRST-TIME SETUP</div><h1>Connect your hotel workspace</h1><p className="setup-copy">Add your Supabase project URL and publishable key to <code>.env.local</code>, then return here to create your organization, property and first rooms.</p><div className="setup-steps"><span>1</span><p>Copy <code>.env.example</code> to <code>.env.local</code></p><span>2</span><p>Enter your Supabase URL and publishable key</p><span>3</span><p>Apply the migrations in <code>supabase/migrations</code></p></div><Link className="button" href="/">Back to demo dashboard</Link></section></main>;
  }

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");
  const { data: memberships } = await supabase.from("organization_memberships").select("organization_id").eq("user_id", user.id).eq("active", true).limit(1);
  if (memberships?.length) redirect("/");

  return <main className="setup-page"><section className="setup-card setup-card-wide"><div className="brand-mark setup-logo">C</div><div className="eyebrow">WELCOME TO COASTLINE</div><h1>Set up your hotel</h1><p className="setup-copy">We’ll create your workspace, first property, standard room type and room list. You can add more room types and staff after setup.</p><HotelSetupForm/></section></main>;
}
