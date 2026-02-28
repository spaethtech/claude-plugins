import { NextRequest, NextResponse } from "next/server";
import { getPluginById } from "@/lib/registry";

export async function GET(
  _request: NextRequest,
  { params }: { params: Promise<{ id: string }> }
) {
  const { id } = await params;
  const plugin = getPluginById(id);

  if (!plugin) {
    return NextResponse.json({ error: "Plugin not found" }, { status: 404 });
  }

  return NextResponse.json(plugin);
}
