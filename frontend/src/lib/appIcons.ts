import {
  Brain,
  CalendarDays,
  FolderOpen,
  Image,
  ListChecks,
  NotebookPen,
  Puzzle,
  Target,
  UserRound,
  Wallet
} from 'lucide-vue-next'
import type { Component } from 'vue'

// An app declares its icon by name (the registry and the servant-app.json
// manifest stay free of Vue imports); this maps the name to the Lucide
// component wherever apps are listed. Unknown names get the puzzle piece.
const icons: Record<string, Component> = {
  Brain,
  CalendarDays,
  FolderOpen,
  Image,
  ListChecks,
  NotebookPen,
  Target,
  UserRound,
  Wallet
}

export function appIcon(name: string): Component {
  return icons[name] ?? Puzzle
}
