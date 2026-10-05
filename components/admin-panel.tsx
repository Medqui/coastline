"use client";

import { useActionState, useEffect, useState } from "react";
import { Check, Copy, LoaderCircle, Plus, Send } from "lucide-react";
import { changeMemberRoleAction, createPropertyAction, createTeamInvitationAction, saveStaffNameAction, type ActionState } from "@/app/actions";

type Member = { userId: string; email: string; fullName: string; role: string; active: boolean };
export function AdminPanel({ organizationId, propertyId, propertyName, members, role }: {
  organizationId: string; propertyId: string; propertyName: string;
  properties: { id: string; name: string }[]; members: Member[]; role: string;
}) {
  return <><div className="page-heading"><div><div className="eyebrow">HOTEL SETTINGS</div><h1>Staff</h1><p>Invite staff and manage their roles and property access.</p></div></div>
    <div className="content-grid two-col">
      <section className="panel"><div className="panel-heading"><div><strong>Invite hotel staff</strong><small>Links expire after 7 days and are limited to a property.</small></div></div>{role === "owner" ? <InviteForm organizationId={organizationId} propertyId={propertyId} propertyName={propertyName}/> : <p className="empty-state">Only the hotel owner can invite staff.</p>}</section>
      <section className="panel"><div className="panel-heading"><div><strong>Team roles</strong><small>Role changes take effect immediately.</small></div></div>{role === "owner" ? <div className="admin-list">{members.filter(member => member.active).map(member => <div key={member.userId}><MemberName organizationId={organizationId} member={member}/><MemberRole organizationId={organizationId} member={member}/></div>)}</div> : <p className="empty-state">Only the hotel owner can change staff roles.</p>}</section>
    </div></>;
}
export function PropertyForm({ organizationId }: { organizationId: string }) {
  const [state, action, pending] = useActionState(createPropertyAction, {} as ActionState);
  return <form action={action} className="reservation-form admin-form"><input type="hidden" name="organization_id" value={organizationId}/>
    <label>Property name<input name="name" required minLength={2} placeholder="e.g. Marina Annex"/></label><label>Address <span className="optional">Optional</span><input name="address" placeholder="Street, Calabar"/></label>
    <div className="reservation-form-row"><label>Rooms<input name="room_count" type="number" min={1} max={300} defaultValue={10} required/></label><label>Standard nightly rate (₦)<input name="standard_rate" type="number" min={0} step="100" required/></label></div>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}{state.success && <p className="admin-success"><Check size={14}/> Property created.</p>}<button className="button button-primary" disabled={pending}>{pending ? <LoaderCircle size={14} className="spin"/> : <Plus size={14}/>}Add property</button>
  </form>;
}
function InviteForm({ organizationId, propertyId, propertyName }: { organizationId: string; propertyId: string; propertyName: string }) {
  const [state, action, pending] = useActionState(createTeamInvitationAction, {} as ActionState);
  const [link, setLink] = useState(""); const [copied, setCopied] = useState(false);
  useEffect(() => { if (state.result) setLink(`${window.location.origin}/team/accept?token=${encodeURIComponent(state.result)}`); }, [state.result]);
  return <form action={action} className="reservation-form admin-form"><input type="hidden" name="organization_id" value={organizationId}/><input type="hidden" name="property_id" value={propertyId}/>
    <label>Full name<input name="full_name" required minLength={2} maxLength={120} placeholder="Staff member’s full name"/></label>
    <label>Email address<input name="email" type="email" autoComplete="off" required placeholder="staff@example.com"/></label>
    <label>Property access<output className="admin-property-output">{propertyName}</output></label>
    <label>Role<select name="role" defaultValue="front_desk"><option value="manager">Manager</option><option value="front_desk">Front desk</option><option value="accountant">Accountant</option><option value="housekeeping">Housekeeping</option></select></label>
    {state.error && <p className="form-error" role="alert">{state.error}</p>}{link && <div className="invite-link"><p>Copy this secure invite link and send it to the staff member. They must sign in with the invited email.</p><input readOnly value={link}/><button type="button" className="button" onClick={async () => { await navigator.clipboard.writeText(link); setCopied(true); }}><Copy size={14}/>{copied ? "Copied" : "Copy invite link"}</button></div>}
    <button className="button button-primary" disabled={pending}>{pending ? <LoaderCircle size={14} className="spin"/> : <Send size={14}/>}Create invite</button>
  </form>;
}
function MemberRole({ organizationId, member }: { organizationId: string; member: Member }) {
  const [state, action, pending] = useActionState(changeMemberRoleAction, {} as ActionState);
  if (member.role === "owner") return <div className="admin-list-row"><span>{member.email}</span><strong>Owner</strong></div>;
  return <form action={action} className="admin-list-row member-role-form"><input type="hidden" name="organization_id" value={organizationId}/><input type="hidden" name="user_id" value={member.userId}/><span>{member.email || `Staff · ${member.userId.slice(0,8)}`}</span><select aria-label="Staff role" name="role" defaultValue={member.role}><option value="manager">Manager</option><option value="front_desk">Front desk</option><option value="accountant">Accountant</option><option value="housekeeping">Housekeeping</option></select><button className="button" disabled={pending}>{pending ? "Saving…" : state.success ? "Saved" : "Update"}</button>{state.error && <small className="form-error">{state.error}</small>}</form>;
}

function MemberName({organizationId,member}:{organizationId:string;member:Member}) {
 const [state,action,pending]=useActionState(saveStaffNameAction,{} as ActionState);
 return <form action={action} className="admin-list-row member-role-form"><input type="hidden" name="organization_id" value={organizationId}/><input type="hidden" name="user_id" value={member.userId}/><input aria-label={`Full name for ${member.email}`} name="full_name" defaultValue={member.fullName} minLength={2} maxLength={120} required placeholder="Staff full name"/><button className="button" disabled={pending}>Save name</button>{state.error&&<small className="form-error">{state.error}</small>}</form>;
}
