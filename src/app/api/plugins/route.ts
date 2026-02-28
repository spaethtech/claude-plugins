import { NextRequest, NextResponse } from "next/server";
import { getRegistry, searchPlugins, getPluginsByCategory } from "@/lib/registry";
import type { PluginCategory } from "@/types/plugin";

export async function GET(request: NextRequest) {
  const { searchParams } = request.nextUrl;
  const query = searchParams.get("q");
  const category = searchParams.get("category");

  if (query) {
    return NextResponse.json({ plugins: searchPlugins(query) });
  }

  if (category) {
    return NextResponse.json({
      plugins: getPluginsByCategory(category as PluginCategory),
    });
  }

  return NextResponse.json(getRegistry());
}
