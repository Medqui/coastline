"use client";

import { createClient } from "@/lib/supabase/client";
import { Button } from "@/components/ui/button";
import { LogOut } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState } from "react";

export function LogoutButton({ compact = false }: { compact?: boolean }) {
  const router = useRouter();
  const [isSigningOut, setIsSigningOut] = useState(false);

  const logout = async () => {
    setIsSigningOut(true);
    const supabase = createClient();
    const { error } = await supabase.auth.signOut();
    if (error) {
      setIsSigningOut(false);
      return;
    }
    router.replace("/auth/login");
    router.refresh();
  };

  return <Button
    type="button"
    variant={compact ? "ghost" : "default"}
    size={compact ? "sm" : "default"}
    className={compact ? "sidebar-logout" : undefined}
    onClick={logout}
    disabled={isSigningOut}
  >
    <LogOut size={14}/>{isSigningOut ? "Signing out…" : "Log out"}
  </Button>;
}
