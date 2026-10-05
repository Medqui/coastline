"use client";
import { Suspense } from "react";
import { useActionState } from "react";
import { useSearchParams } from "next/navigation";
import Link from "next/link";
import { acceptTeamInvitationAction, type ActionState } from "@/app/actions";
function AcceptForm() {
  const token = useSearchParams().get("token") ?? "";
  const [state, action, pending] = useActionState(acceptTeamInvitationAction, {} as ActionState);
  return <main className="setup-page"><section className="setup-card"><div className="eyebrow">COASTLINE PMS · HOTEL TEAM</div><h1>Accept your invitation</h1><p>Sign in with the email address the hotel invited. Access is limited to the assigned property.</p>{state.success ? <div className="admin-success">Invitation accepted. <Link href="/">Open the hotel workspace</Link></div> : <form action={action} className="reservation-form"><input type="hidden" name="token" value={token}/>{state.error && <p className="form-error" role="alert">{state.error}</p>}<button className="button button-primary" disabled={pending || !token}>{pending ? "Joining…" : "Accept invitation"}</button></form>}</section></main>;
}
export default function AcceptInvitationPage() { return <Suspense fallback={<main className="setup-page">Loading invitation…</main>}><AcceptForm/></Suspense>; }
