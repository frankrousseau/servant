export interface ConnectorDef {
  id: string
  name: string
  description: string
  category: string
  logo: string // inline SVG
  configFields: ConfigField[]
  configHint: Record<string, unknown>
}

export interface ConfigField {
  key: string
  label: string
  type: 'text' | 'url' | 'number' | 'select' | 'password' | 'textarea'
  placeholder: string
  required: boolean
  options?: { value: string; label: string }[]
}

// -- SVG Logos (inline, no external deps) --

const RSS_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#F26522"/>
  <circle cx="13" cy="27" r="3.5" fill="#fff"/>
  <path d="M10 17a13 13 0 0 1 13 13" stroke="#fff" stroke-width="3.5" stroke-linecap="round" fill="none"/>
  <path d="M10 10a20 20 0 0 1 20 20" stroke="#fff" stroke-width="3.5" stroke-linecap="round" fill="none"/>
</svg>`

const SOLANA_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="solg" x1="6" y1="30" x2="34" y2="10" gradientUnits="userSpaceOnUse">
    <stop stop-color="#9945FF"/><stop offset="1" stop-color="#14F195"/>
  </linearGradient></defs>
  <rect width="40" height="40" rx="8" fill="#131418"/>
  <g fill="url(#solg)">
    <path d="M13 13h16l-3 3H10z"/>
    <path d="M10 18.5h16l3 3H13z"/>
    <path d="M13 24h16l-3 3H10z"/>
  </g>
</svg>`

const ARBITRUM_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#213147"/>
  <path d="M20 8l10 12-10 12-10-12L20 8z" stroke="#28A0F0" stroke-width="2" fill="none"/>
  <path d="M20 14l5 6-5 6-5-6 5-6z" fill="#28A0F0"/>
</svg>`

const BASE_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#0052FF"/>
  <circle cx="20" cy="20" r="10" fill="#fff"/>
  <path d="M20 12a8 8 0 1 0 0 16V12z" fill="#0052FF"/>
</svg>`

const ETHEREUM_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#627EEA"/>
  <path d="M20 8v9.6l8 3.6L20 8z" fill="#fff" opacity="0.6"/>
  <path d="M20 8l-8 13.2 8-3.6V8z" fill="#fff"/>
  <path d="M20 26.2v5.8l8-11L20 26.2z" fill="#fff" opacity="0.6"/>
  <path d="M20 32v-5.8l-8-5.2 8 11z" fill="#fff"/>
</svg>`

const ICAL_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#E07C5A"/>
  <rect x="9" y="12" width="22" height="18" rx="3" stroke="#fff" stroke-width="2" fill="none"/>
  <line x1="9" y1="18" x2="31" y2="18" stroke="#fff" stroke-width="2"/>
  <line x1="15" y1="10" x2="15" y2="14" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
  <line x1="25" y1="10" x2="25" y2="14" stroke="#fff" stroke-width="2" stroke-linecap="round"/>
  <circle cx="16" cy="23" r="1.5" fill="#fff"/>
  <circle cx="24" cy="23" r="1.5" fill="#fff"/>
  <circle cx="16" cy="27.5" r="1.5" fill="#fff" opacity="0.6"/>
</svg>`

const VCARD_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#3D8B7A"/>
  <circle cx="20" cy="16" r="5" stroke="#fff" stroke-width="2" fill="none"/>
  <path d="M11 30c0-5 4-9 9-9s9 4 9 9" stroke="#fff" stroke-width="2" stroke-linecap="round" fill="none"/>
</svg>`

const APPLE_HEALTH_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#FF2D55"/>
  <path d="M20 28c-5-4-8-7-8-10.5C12 14.5 14 13 16.5 13c1.5 0 2.8.8 3.5 2 .7-1.2 2-2 3.5-2C26 13 28 14.5 28 17.5c0 3.5-3 6.5-8 10.5z" fill="#fff"/>
</svg>`

const BANK_CSV_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#2D6A4F"/>
  <path d="M12 14h16M12 20h16M12 26h10" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>
  <circle cx="28" cy="26" r="3" fill="#95D5B2"/>
</svg>`

const HYPEREVM_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#072723"/>
  <path d="M11 27V13h3.2v5.4h5.1V13h3.2v14h-3.2v-5.7h-5.1V27z" fill="#97FCE4"/>
  <circle cx="28" cy="14" r="2.4" fill="#97FCE4"/>
</svg>`

const INVOICE_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#5B4FC4"/>
  <rect x="11" y="8" width="18" height="24" rx="2" stroke="#fff" stroke-width="2" fill="none"/>
  <line x1="15" y1="15" x2="25" y2="15" stroke="#fff" stroke-width="1.5"/>
  <line x1="15" y1="19" x2="25" y2="19" stroke="#fff" stroke-width="1.5"/>
  <line x1="15" y1="23" x2="21" y2="23" stroke="#fff" stroke-width="1.5"/>
  <circle cx="24" cy="27" r="2" fill="#A5B4FC"/>
</svg>`

const STRAVA_LOGO = `<img src="/strava-logo.png" alt="Strava" width="40" height="40" style="border-radius:8px;display:block" />`

const OVH_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#000E9C"/>
  <path d="M9 26l6-12M17 26l6-12M25 26l6-12" stroke="#fff" stroke-width="2.5" stroke-linecap="round"/>
</svg>`

const GITHUB_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#181717"/>
  <path d="M20 9c-6.1 0-11 4.9-11 11 0 4.9 3.2 9 7.5 10.5.6.1.8-.2.8-.5v-2c-3.1.7-3.7-1.3-3.7-1.3-.5-1.3-1.2-1.6-1.2-1.6-1-.7.1-.7.1-.7 1.1.1 1.7 1.1 1.7 1.1 1 1.7 2.6 1.2 3.2.9.1-.7.4-1.2.7-1.5-2.4-.3-5-1.2-5-5.4 0-1.2.4-2.2 1.1-3-.1-.3-.5-1.4.1-2.9 0 0 .9-.3 3 1.1a10.5 10.5 0 0 1 5.5 0c2.1-1.4 3-1.1 3-1.1.6 1.5.2 2.6.1 2.9.7.8 1.1 1.8 1.1 3 0 4.2-2.6 5.1-5 5.4.4.3.7 1 .7 2v3c0 .3.2.6.8.5A11 11 0 0 0 31 20c0-6.1-4.9-11-11-11z" fill="#fff"/>
</svg>`

const GITLAB_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#171321"/>
  <path d="M20 30 L8.7 21.4 L11.8 11.8 L15.7 18.4 L24.3 18.4 L28.2 11.8 L31.3 21.4 Z" fill="#FC6D26"/>
</svg>`

const ENABLE_BANKING_LOGO = `<svg viewBox="0 0 40 40" fill="none" xmlns="http://www.w3.org/2000/svg">
  <rect width="40" height="40" rx="8" fill="#0E2A47"/>
  <path d="M20 9l11 6H9l11-6z" fill="#7FD1C0"/>
  <rect x="11" y="17" width="3" height="10" fill="#7FD1C0"/>
  <rect x="18.5" y="17" width="3" height="10" fill="#7FD1C0"/>
  <rect x="26" y="17" width="3" height="10" fill="#7FD1C0"/>
  <rect x="9" y="29" width="22" height="3" fill="#7FD1C0"/>
</svg>`

// -- Registry --

export const CONNECTOR_DEFS: ConnectorDef[] = [
  {
    id: 'rss',
    name: 'RSS Feed',
    description: 'Collect articles from your RSS and Atom feeds.',
    category: 'Content',
    logo: RSS_LOGO,
    configFields: [
      {
        key: 'url',
        label: 'Feed URL',
        type: 'url',
        placeholder: 'https://example.com/feed.xml',
        required: true
      }
    ],
    configHint: { url: '' }
  },
  {
    id: 'ical',
    name: 'iCal Calendar',
    description:
      'Collect your events from any iCal (.ics) feed: Google Calendar, Outlook, etc.',
    category: 'Calendar',
    logo: ICAL_LOGO,
    configFields: [
      {
        key: 'url',
        label: 'iCal feed URL',
        type: 'url',
        placeholder:
          'https://calendar.google.com/calendar/ical/.../basic.ics (or import a file)',
        required: false
      },
      {
        key: 'calendar_name',
        label: 'Calendar name',
        type: 'text',
        placeholder: 'e.g. Work, Personal',
        required: false
      }
    ],
    configHint: { url: '', calendar_name: 'Calendar' }
  },
  {
    id: 'solana',
    name: 'Solana Wallet',
    description: 'Collect your SOL and token transfers from a Solana wallet.',
    category: 'Blockchain',
    logo: SOLANA_LOGO,
    configFields: [
      {
        key: 'wallet_address',
        label: 'Wallet address',
        type: 'text',
        placeholder: 'Your Solana address or name.sol',
        required: true
      },
      {
        key: 'rpc_url',
        label: 'Custom RPC URL',
        type: 'url',
        placeholder: 'Leave empty for public RPC',
        required: false
      }
    ],
    configHint: { wallet_address: '', rpc_url: null, min_sol_amount: 1000000 }
  },
  {
    id: 'hyperevm',
    name: 'HyperEVM Wallet',
    description:
      "Collect your HYPE and token transfers from Hyperliquid's EVM.",
    category: 'Blockchain',
    logo: HYPEREVM_LOGO,
    configFields: [
      {
        key: 'wallet_address',
        label: 'Wallet address',
        type: 'text',
        placeholder: '0x... or name.eth',
        required: true
      },
      {
        key: 'explorer_url',
        label: 'Custom explorer URL',
        type: 'url',
        placeholder: 'Leave empty for Etherscan V2',
        required: false
      },
      {
        key: 'api_key',
        label: 'Etherscan API key',
        type: 'password',
        placeholder: 'Free key from etherscan.io (required for Etherscan)',
        required: false
      }
    ],
    configHint: {
      wallet_address: '',
      explorer_url: null,
      min_wei: 1000000000000000
    }
  },
  {
    id: 'arbitrum',
    name: 'Arbitrum Wallet',
    description: 'Collect your ETH and token transfers on Arbitrum One.',
    category: 'Blockchain',
    logo: ARBITRUM_LOGO,
    configFields: [
      {
        key: 'wallet_address',
        label: 'Wallet address',
        type: 'text',
        placeholder: '0x... or name.eth',
        required: true
      },
      {
        key: 'explorer_url',
        label: 'Custom explorer URL',
        type: 'url',
        placeholder: 'Leave empty for Etherscan V2',
        required: false
      },
      {
        key: 'api_key',
        label: 'Etherscan API key',
        type: 'password',
        placeholder: 'Free key from etherscan.io (required for Etherscan)',
        required: false
      }
    ],
    configHint: {
      wallet_address: '',
      explorer_url: null,
      min_wei: 1000000000000000
    }
  },

  {
    id: 'base',
    name: 'Base Wallet',
    description: 'Collect your ETH and token transfers on Base (Coinbase L2).',
    category: 'Blockchain',
    logo: BASE_LOGO,
    configFields: [
      {
        key: 'wallet_address',
        label: 'Wallet address',
        type: 'text',
        placeholder: '0x... or name.eth',
        required: true
      },
      {
        key: 'explorer_url',
        label: 'Custom explorer URL',
        type: 'url',
        placeholder: 'Leave empty for BaseScan',
        required: false
      },
      {
        key: 'api_key',
        label: 'Etherscan API key',
        type: 'password',
        placeholder: 'Free key from etherscan.io (required for Etherscan)',
        required: false
      }
    ],
    configHint: {
      wallet_address: '',
      explorer_url: null,
      min_wei: 1000000000000000
    }
  },
  {
    id: 'ethereum',
    name: 'Ethereum Wallet',
    description: 'Collect your ETH and token transfers on Ethereum mainnet.',
    category: 'Blockchain',
    logo: ETHEREUM_LOGO,
    configFields: [
      {
        key: 'wallet_address',
        label: 'Wallet address',
        type: 'text',
        placeholder: '0x... or name.eth',
        required: true
      },
      {
        key: 'explorer_url',
        label: 'Custom explorer URL',
        type: 'url',
        placeholder: 'Leave empty for Etherscan V2',
        required: false
      },
      {
        key: 'api_key',
        label: 'Etherscan API key',
        type: 'password',
        placeholder: 'Free key from etherscan.io (required for Etherscan)',
        required: false
      }
    ],
    configHint: {
      wallet_address: '',
      explorer_url: null,
      min_wei: 1000000000000000
    }
  },

  {
    id: 'vcard',
    name: 'Contacts (vCard)',
    description:
      'Import your contacts from a vCard (.vcf) file, or subscribe to a URL. An imported file joins your address book and syncs to your phone; a URL stays a read-only feed.',
    category: 'Contacts',
    logo: VCARD_LOGO,
    configFields: [
      {
        key: 'url',
        label: 'vCard URL',
        type: 'url',
        placeholder: 'https://... (or import a .vcf file)',
        required: false
      },
      {
        key: 'source_name',
        label: 'Source name',
        type: 'text',
        placeholder: 'e.g. Google Contacts, iCloud',
        required: false
      }
    ],
    configHint: { url: '', source_name: 'Contacts' }
  },
  {
    id: 'apple_health',
    name: 'Apple Health',
    description:
      'Import your health data from iPhone: steps, heart rate, workouts, sleep, and more.',
    category: 'Health',
    logo: APPLE_HEALTH_LOGO,
    configFields: [],
    configHint: {}
  },
  {
    id: 'bank_csv',
    name: 'Bank Transactions',
    description:
      'Import your bank transactions from a CSV file. Supports Banque Postale, CIC, N26, Revolut, and generic formats.',
    category: 'Banking',
    logo: BANK_CSV_LOGO,
    configFields: [
      {
        key: 'preset',
        label: 'Bank format',
        type: 'select',
        placeholder: '',
        required: true,
        options: [
          { value: 'banque_postale', label: 'La Banque Postale' },
          { value: 'cic', label: 'CIC / Crédit Mutuel' },
          { value: 'n26', label: 'N26' },
          { value: 'revolut', label: 'Revolut' },
          { value: 'generic', label: 'Generic (comma-separated)' }
        ]
      },
      {
        key: 'account_name',
        label: 'Account name',
        type: 'text',
        placeholder: 'e.g. N26 Personal',
        required: false
      }
    ],
    configHint: { preset: 'n26', account_name: 'Bank' }
  },
  {
    id: 'enable_banking',
    name: 'Open Banking (Enable Banking)',
    description:
      'Sync your bank transactions automatically through Enable Banking (PSD2): Banque Postale, CIC, and most EU banks. Consent renews every 90-180 days.',
    category: 'Banking',
    logo: ENABLE_BANKING_LOGO,
    configFields: [
      {
        key: 'application_id',
        label: 'Application ID',
        type: 'text',
        placeholder: 'From the Enable Banking control panel',
        required: true
      },
      {
        key: 'private_key',
        label: 'Private key (PEM)',
        type: 'textarea',
        placeholder: '-----BEGIN RSA PRIVATE KEY-----',
        required: true
      },
      {
        key: 'bank_name',
        label: 'Bank name',
        type: 'text',
        placeholder: 'As listed by Enable Banking, e.g. La Banque Postale',
        required: true
      },
      {
        key: 'country',
        label: 'Country code',
        type: 'text',
        placeholder: 'FR',
        required: false
      }
    ],
    configHint: {
      application_id: '',
      private_key: '',
      bank_name: '',
      country: 'FR'
    }
  },
  {
    id: 'ovh',
    name: 'OVH',
    description:
      'Collect your OVH invoices and their PDFs (stored in Files) through the official signed API.',
    category: 'Billing',
    logo: OVH_LOGO,
    configFields: [
      {
        key: 'application_key',
        label: 'Application key',
        type: 'text',
        placeholder: 'From eu.api.ovh.com/createToken',
        required: true
      },
      {
        key: 'application_secret',
        label: 'Application secret',
        type: 'password',
        placeholder: '',
        required: true
      },
      {
        key: 'consumer_key',
        label: 'Consumer key',
        type: 'password',
        placeholder: '',
        required: true
      },
      {
        key: 'endpoint',
        label: 'API endpoint',
        type: 'url',
        placeholder: 'Leave empty for eu.api.ovh.com',
        required: false
      }
    ],
    configHint: {
      application_key: '',
      application_secret: '',
      consumer_key: '',
      endpoint: null
    }
  },
  {
    id: 'invoice_scraper',
    name: 'Invoice Collector',
    description:
      'Collect your invoices from online services: Anthropic, Bouygues Telecom, EDF.',
    category: 'Billing',
    logo: INVOICE_LOGO,
    configFields: [
      {
        key: 'provider',
        label: 'Service',
        type: 'select',
        placeholder: '',
        required: true,
        options: [
          { value: 'anthropic', label: 'Anthropic' },
          { value: 'bouygues', label: 'Bouygues Telecom' },
          { value: 'edf', label: 'EDF' }
        ]
      },
      {
        key: 'email',
        label: 'Email',
        type: 'text',
        placeholder: 'your@email.com',
        required: true
      },
      {
        key: 'password',
        label: 'Password',
        type: 'password',
        placeholder: '',
        required: true
      },
      {
        key: 'totp_secret',
        label: 'TOTP secret',
        type: 'text',
        placeholder: 'Base32 secret for 2FA (optional)',
        required: false
      }
    ],
    configHint: {
      provider: 'anthropic',
      email: '',
      password: '',
      totp_secret: ''
    }
  },
  {
    id: 'github',
    name: 'GitHub',
    description:
      'Collect the metadata of your commits across all your GitHub repositories.',
    category: 'Development',
    logo: GITHUB_LOGO,
    configFields: [
      {
        key: 'username',
        label: 'Username',
        type: 'text',
        placeholder: 'Your GitHub login',
        required: true
      },
      {
        key: 'token',
        label: 'Personal Access Token',
        type: 'password',
        placeholder: 'PAT with read access to your repositories',
        required: true
      },
      {
        key: 'exclude_repos',
        label: 'Excluded repositories',
        type: 'text',
        placeholder: 'owner/repo or owner/*, comma-separated',
        required: false
      }
    ],
    configHint: { username: '', token: '' }
  },
  {
    id: 'gitlab',
    name: 'GitLab',
    description:
      'Collect the metadata of your commits across all your GitLab projects (gitlab.com or self-hosted).',
    category: 'Development',
    logo: GITLAB_LOGO,
    configFields: [
      {
        key: 'author',
        label: 'Commit author',
        type: 'text',
        placeholder: 'Name or email as recorded in your commits',
        required: true
      },
      {
        key: 'token',
        label: 'Personal Access Token',
        type: 'password',
        placeholder: 'PAT with read_api scope',
        required: true
      },
      {
        key: 'base_url',
        label: 'Instance URL (optional)',
        type: 'url',
        placeholder: 'https://gitlab.com',
        required: false
      }
    ],
    configHint: { author: '', token: '', base_url: '' }
  },
  {
    id: 'strava',
    name: 'Strava',
    description: 'Collect your runs, rides, and other activities from Strava.',
    category: 'Fitness',
    logo: STRAVA_LOGO,
    configFields: [
      {
        key: 'client_id',
        label: 'Client ID',
        type: 'text',
        placeholder: 'Your Strava API application client ID',
        required: true
      },
      {
        key: 'client_secret',
        label: 'Client Secret',
        type: 'password',
        placeholder: 'Your Strava API application client secret',
        required: true
      },
      {
        key: 'refresh_token',
        label: 'Refresh Token',
        type: 'password',
        placeholder: 'OAuth refresh token from the authorization flow',
        required: true
      }
    ],
    configHint: { client_id: '', client_secret: '', refresh_token: '' }
  }
]

export function getConnectorDef(id: string): ConnectorDef | undefined {
  return CONNECTOR_DEFS.find(c => c.id === id)
}

// The wallet connectors, hidden along with the rest of crypto when the user
// has not opted in (Settings > Apps).
export const BLOCKCHAIN_CATEGORY = 'Blockchain'

export function blockchainConnector(id: string): boolean {
  return getConnectorDef(id)?.category === BLOCKCHAIN_CATEGORY
}
