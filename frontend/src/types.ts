export interface User {
  id: string;
  username: string;
  display_name: string;
  email: string | null;
  avatar_path: string | null;
}

export interface Entry {
  id: string;
  kind: string;
  source: string;
  external_id: string | null;
  title: string | null;
  occurred_at: string | null;
  data: Record<string, unknown>;
  metadata: Record<string, unknown>;
  inserted_at: string;
  updated_at: string;
}

export interface PaginationMeta {
  page: number;
  per_page: number;
  total: number;
  total_pages: number;
}

export type Schedule =
  | "on_demand"
  | "every_5_minutes"
  | "every_hour"
  | "every_day"
  | "every_week"
  | "continuous";

export const SCHEDULE_LABELS: Record<Schedule, string> = {
  on_demand: "On demand",
  every_5_minutes: "Every 5 minutes",
  every_hour: "Every hour",
  every_day: "Every day",
  every_week: "Every week",
  continuous: "Continuous",
};

export interface ConnectorConfig {
  id: string;
  connector_type: string;
  name: string | null;
  enabled: boolean;
  config: Record<string, unknown>;
  schedule: Schedule;
  last_synced_at: string | null;
  error: string | null;
  inserted_at: string;
  updated_at: string;
}

export interface SyncLog {
  id: string;
  status: "running" | "completed" | "failed";
  entries_count: number;
  error: string | null;
  started_at: string;
  finished_at: string | null;
}

export interface App {
  id: string;
  name: string;
  description: string;
  icon: string | null;
  route: string;
}

// Kind icons/colors for visual differentiation
export const KIND_CONFIG: Record<string, { icon: string; color: string }> = {
  transaction: { icon: "↔", color: "#6c8cff" },
  article: { icon: "¶", color: "#f0a06c" },
  email: { icon: "@", color: "#5cc98a" },
  photo: { icon: "◻", color: "#c96cd0" },
  contact: { icon: "●", color: "#6ccec9" },
  note: { icon: "✎", color: "#e0d56c" },
};

export function kindIcon(kind: string): string {
  return KIND_CONFIG[kind]?.icon ?? "·";
}

export function kindColor(kind: string): string {
  return KIND_CONFIG[kind]?.color ?? "#8b8fa3";
}

export function relativeTime(dateStr: string): string {
  const date = new Date(dateStr);
  const now = new Date();
  const diffMs = now.getTime() - date.getTime();
  const diffSec = Math.floor(diffMs / 1000);
  const diffMin = Math.floor(diffSec / 60);
  const diffHour = Math.floor(diffMin / 60);
  const diffDay = Math.floor(diffHour / 24);

  if (diffSec < 60) return "just now";
  if (diffMin < 60) return `${diffMin}m ago`;
  if (diffHour < 24) return `${diffHour}h ago`;
  if (diffDay < 7) return `${diffDay}d ago`;
  return date.toLocaleDateString();
}
