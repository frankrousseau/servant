import type { AppDef } from "./types";

export const BUILTIN_APPS: AppDef[] = [
  {
    id: "contacts",
    name: "Contacts",
    icon: "UserRound",
    builtin: true,
    load: () => import("./contacts"),
  },
  {
    id: "calendar",
    name: "Calendar",
    icon: "CalendarDays",
    builtin: true,
    load: () => import("./calendar"),
  },
  {
    id: "files",
    name: "Files",
    icon: "FolderOpen",
    builtin: true,
    load: () => import("./files"),
  },
  {
    id: "photos",
    name: "Photos",
    icon: "Image",
    builtin: true,
    load: () => import("./photos"),
  },
  {
    id: "notes",
    name: "Notes",
    icon: "NotebookPen",
    builtin: true,
    load: () => import("./notes"),
  },
  {
    id: "checklists",
    name: "Checklists",
    icon: "ListChecks",
    builtin: true,
    load: () => import("./checklists"),
  },
];

export function getAppDef(id: string): AppDef | undefined {
  return BUILTIN_APPS.find((a) => a.id === id);
}
