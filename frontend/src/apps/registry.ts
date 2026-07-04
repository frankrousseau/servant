import type { AppDef } from "./types";

// Alphabetical by name — this array is the sidebar display order.
export const BUILTIN_APPS: AppDef[] = [
  {
    id: "calendar",
    name: "Calendar",
    icon: "CalendarDays",
    builtin: true,
    load: () => import("./calendar"),
  },
  {
    id: "checklists",
    name: "Checklists",
    icon: "ListChecks",
    builtin: true,
    load: () => import("./checklists"),
  },
  {
    id: "contacts",
    name: "Contacts",
    icon: "UserRound",
    builtin: true,
    load: () => import("./contacts"),
  },
  {
    id: "files",
    name: "Files",
    icon: "FolderOpen",
    builtin: true,
    load: () => import("./files"),
  },
  {
    id: "notes",
    name: "Notes",
    icon: "NotebookPen",
    builtin: true,
    load: () => import("./notes"),
  },
  {
    id: "photos",
    name: "Photos",
    icon: "Image",
    builtin: true,
    load: () => import("./photos"),
  },
];

export function getAppDef(id: string): AppDef | undefined {
  return BUILTIN_APPS.find((a) => a.id === id);
}
