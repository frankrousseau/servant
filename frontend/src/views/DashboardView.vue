<script setup lang="ts">
import { ref, onMounted } from "vue";
import { useRouter } from "vue-router";
import { useApi } from "../composables/useApi";
import { useSocket } from "../composables/useSocket";
import type { Entry, ConnectorConfig } from "../types";
import { relativeTime } from "../types";
import { getConnectorDef } from "../connectors";
import KindIcon from "../components/KindIcon.vue";

const api = useApi();
const router = useRouter();

const recentEntries = ref<Entry[]>([]);
const stats = ref<Record<string, number>>({});
const totalEntries = ref(0);
const connectors = ref<ConnectorConfig[]>([]);
const loading = ref(true);

const { onEntryChange } = useSocket();

onEntryChange(() => {
  fetchData();
});

async function fetchData() {
  try {
    const [entriesRes, statsRes, connectorsRes] = await Promise.all([
      api.get<{ data: Entry[]; meta: { total: number } }>("/api/entries", {
        per_page: "10",
        sort: "inserted_at",
      }),
      api.get<{ data: Record<string, number>; total: number }>(
        "/api/entries/stats",
      ),
      api.get<{ data: ConnectorConfig[] }>("/api/connectors"),
    ]);
    recentEntries.value = entriesRes.data;
    stats.value = statsRes.data;
    totalEntries.value = statsRes.total;
    connectors.value = connectorsRes.data;
  } catch {
    // API not available yet
  } finally {
    loading.value = false;
  }
}

function goToData(kind?: string) {
  if (kind) {
    router.push({ path: "/data", query: { kind } });
  } else {
    router.push("/data");
  }
}

function goToEntry(entry: Entry) {
  router.push({ path: "/data", query: { entry: entry.id.toString() } });
}

onMounted(fetchData);
</script>

<template>
  <div class="view">
    <p v-if="loading" class="loading-text">Loading...</p>

    <template v-else>
      <div class="dashboard-layout">
        <!-- Main column: Recent activity -->
        <div class="dashboard-main">
          <section class="dashboard-section">
            <div class="section-header">
              <h2>Recent Activity</h2>
              <router-link to="/data" class="section-link">View all</router-link>
            </div>
            <div v-if="recentEntries.length" class="activity-feed">
              <div
                v-for="entry in recentEntries"
                :key="entry.id"
                class="activity-item"
                @click="goToEntry(entry)"
                role="button"
                tabindex="0"
              >
                <KindIcon :kind="entry.kind" :size="16" />
                <div class="activity-body">
                  <span class="activity-title">
                    {{ entry.title || entry.kind }}
                  </span>
                  <span class="activity-meta">
                    {{ entry.source }}
                    <template v-if="entry.occurred_at">
                      &middot; {{ relativeTime(entry.occurred_at) }}
                    </template>
                  </span>
                </div>
                <span class="activity-kind-badge">{{ entry.kind }}</span>
              </div>
            </div>
            <p v-else class="empty">No entries yet. Set up a connector to start collecting data.</p>
          </section>
        </div>

        <!-- Right sidebar: Stats + Connectors -->
        <aside class="dashboard-sidebar">
          <!-- Stats -->
          <section class="sidebar-section">
            <h2>Statistics</h2>
            <div class="sidebar-stats">
              <div
                class="stat-card stat-card--total"
                @click="goToData()"
                role="button"
                tabindex="0"
              >
                <div class="stat-icon-badge stat-icon-badge--total">
                  <span class="stat-icon-text">&Sigma;</span>
                </div>
                <div class="stat-content">
                  <span class="stat-count">{{ totalEntries }}</span>
                  <span class="stat-label">Total entries</span>
                </div>
              </div>
              <div
                v-for="(count, kind) in stats"
                :key="kind"
                class="stat-card"
                @click="goToData(kind as string)"
                role="button"
                tabindex="0"
              >
                <div class="stat-icon-badge">
                  <KindIcon :kind="(kind as string)" :size="18" />
                </div>
                <div class="stat-content">
                  <span class="stat-count">{{ count }}</span>
                  <span class="stat-label">{{ kind }}</span>
                </div>
              </div>
            </div>
          </section>

          <!-- Connectors status -->
          <section v-if="connectors.length" class="sidebar-section">
            <div class="section-header">
              <h2>Connectors</h2>
              <router-link to="/connectors" class="section-link">Manage</router-link>
            </div>
            <div class="connector-status-list">
              <div
                v-for="c in connectors"
                :key="c.id"
                class="connector-status-item"
              >
                <span
                  v-if="getConnectorDef(c.connector_type)"
                  class="connector-mini-logo"
                  v-html="getConnectorDef(c.connector_type)!.logo"
                ></span>
                <span
                  class="connector-dot"
                  :class="{ active: c.enabled, error: c.error }"
                ></span>
                <span class="connector-status-name">
                  {{ getConnectorDef(c.connector_type)?.name || c.connector_type }}
                </span>
                <span class="connector-status-meta">
                  <template v-if="c.error">Error</template>
                  <template v-else-if="c.last_synced_at">
                    {{ relativeTime(c.last_synced_at) }}
                  </template>
                  <template v-else>Never synced</template>
                </span>
              </div>
            </div>
          </section>
        </aside>
      </div>
    </template>
  </div>
</template>

<style scoped>
.loading-text {
  color: var(--text-muted);
}

/* Two-column layout */
.dashboard-layout {
  display: grid;
  grid-template-columns: 1fr 300px;
  gap: 2rem;
  align-items: start;
}

@media (max-width: 860px) {
  .dashboard-layout {
    grid-template-columns: 1fr;
  }
}

.dashboard-main {
  min-width: 0;
}

/* Sidebar */
.dashboard-sidebar {
  display: flex;
  flex-direction: column;
  gap: 1.5rem;
}

.sidebar-section h2 {
  margin: 0 0 0.75rem;
}

/* Stats */
.sidebar-stats {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: 0.625rem;
}

.stat-card {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 0.875rem;
  display: flex;
  align-items: flex-start;
  gap: 0.625rem;
  cursor: pointer;
  transition: border-color 0.2s, box-shadow 0.2s;
}

.stat-card:hover {
  border-color: var(--primary);
  box-shadow: 0 2px 12px rgba(108, 140, 255, 0.1);
}

.stat-card--total {
  grid-column: 1 / -1;
  background: linear-gradient(135deg, rgba(108, 140, 255, 0.12), rgba(108, 140, 255, 0.04));
  border-color: rgba(108, 140, 255, 0.3);
}

.stat-icon-badge {
  flex-shrink: 0;
  width: 36px;
  height: 36px;
  border-radius: 8px;
  background: rgba(108, 140, 255, 0.12);
  color: var(--primary);
  display: flex;
  align-items: center;
  justify-content: center;
}

.stat-icon-badge--total {
  background: linear-gradient(135deg, var(--primary), var(--primary-hover));
  color: #fff;
}

.stat-icon-text {
  font-size: 1.1rem;
  font-weight: 700;
  line-height: 1;
}

.stat-content {
  display: flex;
  flex-direction: column;
  gap: 0.125rem;
  min-width: 0;
}

.stat-count {
  font-weight: 700;
  font-size: 1.25rem;
  line-height: 1.2;
  color: var(--text);
}

.stat-label {
  font-size: 0.75rem;
  color: var(--text-muted);
  text-transform: capitalize;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Sections */
.dashboard-section {
  margin-bottom: 2rem;
}

.section-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 0.75rem;
}

.section-header h2 {
  margin: 0;
}

.section-link {
  font-size: 0.9rem;
}

/* Connector status */
.connector-status-list {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
}

.connector-status-item {
  background: var(--bg-surface);
  border: 1px solid var(--border);
  border-radius: var(--radius);
  padding: 0.6rem 1rem;
  display: flex;
  align-items: center;
  gap: 0.5rem;
  font-size: 0.9rem;
}

.connector-mini-logo {
  width: 22px;
  height: 22px;
  flex-shrink: 0;
  border-radius: 4px;
  overflow: hidden;
  background: #000;
}

.connector-mini-logo :deep(svg),
.connector-mini-logo :deep(img) {
  width: 100%;
  height: 100%;
  display: block;
}

.connector-dot {
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--text-muted);
  flex-shrink: 0;
}

.connector-dot.active {
  background: var(--success);
}

.connector-dot.error {
  background: var(--danger);
}

.connector-status-name {
  font-weight: 500;
}

.connector-status-meta {
  color: var(--text-muted);
  margin-left: auto;
  font-size: 0.85rem;
}

/* Activity feed */
.activity-feed {
  display: flex;
  flex-direction: column;
}

.activity-item {
  display: flex;
  align-items: center;
  gap: 0.75rem;
  padding: 0.75rem 0.5rem;
  border-bottom: 1px solid var(--border);
  cursor: pointer;
  transition: background 0.1s;
  border-radius: var(--radius);
}

.activity-item:last-child {
  border-bottom: none;
}

.activity-item:hover {
  background: var(--bg-hover);
}

.activity-body {
  flex: 1;
  min-width: 0;
  display: flex;
  flex-direction: column;
}

.activity-title {
  font-size: 1rem;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.activity-meta {
  font-size: 0.875rem;
  color: var(--text-muted);
}

.activity-kind-badge {
  font-size: 0.9rem;
  color: var(--text-muted);
  background: var(--bg-hover);
  padding: 0.15rem 0.5rem;
  border-radius: var(--radius);
  white-space: nowrap;
}
</style>
