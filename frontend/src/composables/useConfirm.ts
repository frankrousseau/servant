import { ref } from "vue";

const visible = ref(false);
const title = ref("");
const message = ref("");
const confirmLabel = ref("Delete");
const danger = ref(true);
let resolveFn: ((value: boolean) => void) | null = null;

export function useConfirm() {
  function ask(opts: {
    title?: string;
    message: string;
    confirmLabel?: string;
    danger?: boolean;
  }): Promise<boolean> {
    // Single shared modal: if a previous ask() is still pending (its promise
    // never settled), resolve it as cancelled before reusing the slot — else
    // that awaiter would hang forever, freezing whatever UI awaited it.
    if (resolveFn) {
      resolveFn(false);
      resolveFn = null;
    }

    title.value = opts.title || "Confirm";
    message.value = opts.message;
    confirmLabel.value = opts.confirmLabel || "Delete";
    danger.value = opts.danger ?? true;
    visible.value = true;

    return new Promise((resolve) => {
      resolveFn = resolve;
    });
  }

  function resolve(value: boolean) {
    visible.value = false;
    resolveFn?.(value);
    resolveFn = null;
  }

  return { visible, title, message, confirmLabel, danger, ask, resolve };
}
