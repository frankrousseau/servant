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

export interface EntriesAPI {
  list(filters?: Record<string, string>): Promise<Entry[]>;
  get(id: string): Promise<Entry>;
  create(attrs: Record<string, unknown>): Promise<Entry>;
  update(id: string, attrs: Record<string, unknown>): Promise<Entry>;
  delete(id: string): Promise<void>;
  stats(): Promise<Record<string, number>>;
}

export interface UploadResult {
  path: string;
  filename: string;
  size: number;
  mime_type: string;
}

export interface ViewerItem {
  id: string;
  src: string;
  title?: string;
  subtitle?: string;
  meta?: Record<string, string | number | null>;
}

export interface ViewerAPI {
  open(items: ViewerItem[], startIndex?: number): void;
  close(): void;
  onDelete(cb: (id: string) => void): void;
}

export interface ConfirmAPI {
  ask(opts: { title?: string; message: string; confirmLabel?: string; danger?: boolean }): Promise<boolean>;
}

export interface AppContext {
  navigate(path: string): void;
  confirm: ConfirmAPI;
  api: {
    entries: EntriesAPI;
    upload(file: File, app?: string): Promise<UploadResult>;
    fetch(path: string, opts?: RequestInit): Promise<Response>;
  };
  viewer: ViewerAPI;
}

export interface AppModule {
  mount(el: HTMLElement, ctx: AppContext): void | Promise<void>;
  unmount?(el: HTMLElement): void;
}

export interface AppDef {
  id: string;
  name: string;
  icon: string;
  builtin: boolean;
  load: () => Promise<{ default: AppModule }>;
}
