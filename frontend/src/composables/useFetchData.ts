import { ref, onMounted, type Ref } from "vue";

interface UseFetchDataOptions<T> {
  /** Run the fetch automatically on mount (default: true). */
  immediate?: boolean;
  /** Value `data` holds before the first successful fetch (default: null). */
  initialValue?: T;
  /** Message used when a thrown error carries none. */
  fallbackError?: string;
  /** Called with the result after each successful fetch. */
  onSuccess?: (data: T) => void;
}

interface UseFetchDataReturn<T> {
  data: Ref<T | null>;
  loading: Ref<boolean>;
  error: Ref<string>;
  refetch: () => Promise<void>;
}

/**
 * Wraps the recurring "load some data into a ref with loading/error state"
 * pattern. Returns reactive `data`, `loading` and `error`, plus a `refetch`
 * to re-run the fetch on demand.
 */
export function useFetchData<T>(
  fetcher: () => Promise<T>,
  options: UseFetchDataOptions<T> = {},
): UseFetchDataReturn<T> {
  const immediate = options.immediate !== false;
  const data = ref(options.initialValue ?? null) as Ref<T | null>;
  const loading = ref(immediate);
  const error = ref("");

  async function refetch() {
    loading.value = true;
    error.value = "";
    try {
      const result = await fetcher();
      data.value = result;
      options.onSuccess?.(result);
    } catch (e) {
      error.value =
        (e instanceof Error && e.message) || options.fallbackError || "Something went wrong";
    } finally {
      loading.value = false;
    }
  }

  if (immediate) {
    onMounted(refetch);
  }

  return { data, loading, error, refetch };
}
