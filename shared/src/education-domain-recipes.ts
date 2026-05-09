export type EducationDomainRecipeId =
  | 'google-classroom'
  | 'microsoft-365-education'
  | 'moodle'
  | 'youtube-educational';

export interface EducationDomainRecipe {
  readonly id: EducationDomainRecipeId;
  readonly name: string;
  readonly description: string;
  readonly domains: readonly string[];
}

export const EDUCATION_DOMAIN_RECIPES = [
  {
    id: 'google-classroom',
    name: 'Google Classroom',
    description: 'Core domains commonly needed for Google Classroom and Drive workflows.',
    domains: [
      'classroom.google.com',
      'accounts.google.com',
      'apis.google.com',
      'fonts.googleapis.com',
      'lh3.googleusercontent.com',
      'drive.google.com',
      'docs.google.com',
    ],
  },
  {
    id: 'microsoft-365-education',
    name: 'Microsoft 365 Education',
    description:
      'Core Microsoft 365 Education domains plus admin-configured SharePoint tenant domains.',
    domains: [
      'login.microsoftonline.com',
      'graph.microsoft.com',
      'cdn.office.net',
      'teams.microsoft.com',
    ],
  },
  {
    id: 'moodle',
    name: 'Moodle',
    description:
      'Baseline Moodle service domains; admins should also add their center domain and CDN domains.',
    domains: ['moodle.org', 'moodle.com'],
  },
  {
    id: 'youtube-educational',
    name: 'YouTube Educational',
    description: 'Core domains needed for YouTube educational video playback and thumbnails.',
    domains: ['youtube.com', 'ytimg.com', 'googlevideo.com', 'yt3.ggpht.com'],
  },
] as const satisfies readonly EducationDomainRecipe[];

export type LocalLearningState =
  | 'observed'
  | 'candidate'
  | 'session_allow'
  | 'local_confirmed'
  | 'expired';

export const LOCAL_LEARNING_DEFAULT_ENABLED = false;
export const LOCAL_LEARNING_STATES = [
  'observed',
  'candidate',
  'session_allow',
  'local_confirmed',
  'expired',
] as const satisfies readonly LocalLearningState[];
