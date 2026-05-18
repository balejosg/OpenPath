import React, { createContext, useContext, useMemo } from 'react';

export const SUPPORTED_PRODUCT_LOCALES = ['en', 'es'] as const;
export type ProductLocale = (typeof SUPPORTED_PRODUCT_LOCALES)[number];

export const productI18nCatalogs = {
  en: {
    'app.title.dashboard.admin': 'Overview',
    'app.title.dashboard.user': 'My Dashboard',
    'app.title.classrooms.admin': 'Classroom Management',
    'app.title.classrooms.user': 'Classrooms',
    'app.title.groups.admin': 'Groups and Policies',
    'app.title.groups.user': 'My Policies',
    'app.title.rules.default': 'Rules Management',
    'app.title.rules.group': 'Rules: {groupName}',
    'app.title.users.admin': 'User Administration',
    'app.title.domainRequests.admin': 'Access Requests',
    'app.title.settings': 'Settings',
    'sidebar.nav.dashboard.admin': 'Dashboard',
    'sidebar.nav.dashboard.user': 'My Dashboard',
    'sidebar.nav.classrooms.admin': 'Secure Classrooms',
    'sidebar.nav.classrooms.user': 'Classrooms',
    'sidebar.nav.groups.admin': 'Group Policies',
    'sidebar.nav.groups.user': 'My Policies',
    'sidebar.nav.users': 'Users and Roles',
    'sidebar.nav.domainRequests': 'Domain Control',
    'sidebar.nav.settings': 'Settings',
    'sidebar.nav.logout': 'Sign Out',
    'sidebar.section.mainMenu': 'Main Menu',
    'auth.common.errorLabel': 'Error:',
    'auth.common.email': 'Email',
    'auth.common.password': 'Password',
    'auth.common.signIn': 'Sign in',
    'auth.common.signInLoading': 'Signing in...',
    'auth.common.requestAccess': 'Request access',
    'auth.common.alreadyHaveAccount': 'Already have an account? ',
    'auth.common.newToPlatform': 'New to the platform? ',
    'auth.login.heroTitle': 'Simplified security for your learning environment.',
    'auth.login.heroBody':
      'Centralized management built for stability, control, and peace of mind at your institution.',
    'auth.login.secureConnection': 'Secure connection',
    'auth.login.openSource': 'Open source',
    'auth.login.title': 'Secure Sign In',
    'auth.login.subtitle': 'Enter your administrator credentials',
    'auth.login.invalidCredentials': 'Invalid credentials or connection error',
    'auth.login.googleError': 'Google sign-in failed',
    'auth.login.rememberSession': 'Keep me signed in',
    'auth.login.recoverPassword': 'Recover password',
    'auth.login.alternativeDivider': 'Or continue with',
    'auth.register.heroTitle': 'Join the secure network.',
    'auth.register.featureGranularTitle': 'Granular control',
    'auth.register.featureGranularBody':
      'Define specific permissions by classroom, group, or individual user.',
    'auth.register.featureAuditTitle': 'Complete audit trail',
    'auth.register.featureAuditBody': 'Immutable record of every administrative action.',
    'auth.register.title': 'Institution Registration',
    'auth.register.subtitle': 'Create a new administrator account',
    'auth.register.successLabel': 'Welcome!',
    'auth.register.successBody': 'Account created successfully. Redirecting to Dashboard...',
    'auth.register.fullName': 'Full name',
    'auth.register.fullNamePlaceholder': 'Your full name',
    'auth.register.corporateEmail': 'Work email',
    'auth.register.role': 'Role',
    'auth.register.role.itDirector': 'IT Director',
    'auth.register.role.systemsAdmin': 'Systems Administrator',
    'auth.register.role.academicCoordinator': 'Academic Coordinator',
    'auth.register.confirmPassword': 'Confirm',
    'auth.register.passwordMinShort': 'Minimum 8 characters',
    'auth.register.termsPrefix': 'By registering, you accept our ',
    'auth.register.termsLink': 'Terms of Service',
    'auth.register.termsSuffix':
      ' and confirm that you represent a verified educational institution. External access is enabled after institutional approval.',
    'auth.register.createAccount': 'Create Account',
    'auth.register.createError': 'Unable to register account',
    'auth.validation.passwordMismatch': 'Passwords do not match',
    'auth.validation.passwordMin': 'Password must be at least 8 characters',
    'rules.type.whitelist.label': 'Allowed domain',
    'rules.type.whitelist.badge': 'Allowed',
    'rules.type.whitelist.export': 'Allowed',
    'rules.type.blockedSubdomain.label': 'Blocked subdomain',
    'rules.type.blockedSubdomain.badge': 'Sub. blocked',
    'rules.type.blockedSubdomain.export': 'Blocked subdomain',
    'rules.type.blockedPath.label': 'Blocked path',
    'rules.type.blockedPath.badge': 'Path blocked',
    'rules.type.blockedPath.export': 'Blocked path',
    'rules.detect.pathReason': 'Contains a path (/)',
    'rules.detect.subdomainExistingReason':
      '"{rootDomain}" is already allowed, so this subdomain will be blocked',
    'rules.detect.wildcardExistingReason': 'Wildcard pattern to block subdomains of "{baseRoot}"',
    'rules.detect.wildcardReason': 'Wildcard pattern detected',
    'rules.detect.whitelistReason': 'Domain to add to the allowlist',
    'rules.validation.empty': 'The value cannot be empty',
    'rules.validation.domainTooShort': 'Domain is too short (minimum 4 characters)',
    'rules.validation.domainTooLong': 'Domain exceeds the allowed 253 characters',
    'rules.validation.domainConsecutiveDots': 'Domain cannot contain consecutive dots (..)',
    'rules.validation.domainInvalidFormat': 'Invalid domain format. Valid example: example.com',
    'rules.validation.domainLabelTooLong': 'Each domain label must be at most 63 characters',
    'rules.validation.subdomainTooShort': 'Subdomain is too short (minimum 4 characters)',
    'rules.validation.subdomainTooLong': 'Subdomain exceeds the allowed 253 characters',
    'rules.validation.subdomainConsecutiveDots': 'Subdomain cannot contain consecutive dots (..)',
    'rules.validation.subdomainInvalidFormat':
      'Invalid subdomain format. Valid example: sub.example.com or *.example.com',
    'rules.validation.subdomainLabelTooLong': 'Each subdomain label must be at most 63 characters',
    'rules.validation.pathMissingSlash': 'Path must contain a slash (/). Example: example.com/path',
    'rules.validation.pathEmpty': 'Path after the domain cannot be empty',
    'rules.validation.pathInvalidChars': 'Path contains unsupported characters (spaces)',
    'rules.validation.pathInvalidDomain': 'Invalid domain in path: {domainError}',
    'rules.validation.invalidFormat': 'Invalid format',
    'rules.group.status.allowed': 'Allowed',
    'rules.group.status.blocked': 'Blocked',
    'rules.group.status.mixed': 'Mixed',
    'rules.group.globalPaths': 'Global paths',
    'rules.group.selectGroup': 'Select group',
    'rules.group.deselectGroup': 'Deselect group',
    'rules.group.addSubdomain': 'Add subdomain to {rootDomain}',
  },
  es: {
    'app.title.dashboard.admin': 'Vista General',
    'app.title.dashboard.user': 'Mi Panel',
    'app.title.classrooms.admin': 'Gestión de Aulas',
    'app.title.classrooms.user': 'Aulas',
    'app.title.groups.admin': 'Grupos y Políticas',
    'app.title.groups.user': 'Mis Políticas',
    'app.title.rules.default': 'Gestión de Reglas',
    'app.title.rules.group': 'Reglas: {groupName}',
    'app.title.users.admin': 'Administración de Usuarios',
    'app.title.domainRequests.admin': 'Solicitudes de Acceso',
    'app.title.settings': 'Configuración',
    'sidebar.nav.dashboard.admin': 'Panel de Control',
    'sidebar.nav.dashboard.user': 'Mi Panel',
    'sidebar.nav.classrooms.admin': 'Aulas Seguras',
    'sidebar.nav.classrooms.user': 'Aulas',
    'sidebar.nav.groups.admin': 'Políticas de Grupo',
    'sidebar.nav.groups.user': 'Mis Políticas',
    'sidebar.nav.users': 'Usuarios y Roles',
    'sidebar.nav.domainRequests': 'Control de Dominios',
    'sidebar.nav.settings': 'Configuración',
    'sidebar.nav.logout': 'Cerrar Sesión',
    'sidebar.section.mainMenu': 'Menu Principal',
    'auth.common.errorLabel': 'Error:',
    'auth.common.email': 'Correo electrónico',
    'auth.common.password': 'Contraseña',
    'auth.common.signIn': 'Entrar',
    'auth.common.signInLoading': 'Entrando...',
    'auth.common.requestAccess': 'Solicitar acceso',
    'auth.common.alreadyHaveAccount': '¿Ya tienes cuenta? ',
    'auth.common.newToPlatform': '¿Nuevo en la plataforma? ',
    'auth.login.heroTitle': 'Seguridad simplificada para tu entorno educativo.',
    'auth.login.heroBody':
      'Plataforma de gestión centralizada diseñada para la estabilidad, el control y la tranquilidad de tu institución.',
    'auth.login.secureConnection': 'Conexión segura',
    'auth.login.openSource': 'Código abierto',
    'auth.login.title': 'Acceso seguro',
    'auth.login.subtitle': 'Ingresa tus credenciales de administrador',
    'auth.login.invalidCredentials': 'Credenciales inválidas o error de conexión',
    'auth.login.googleError': 'Error al iniciar sesión con Google',
    'auth.login.rememberSession': 'Mantener sesión',
    'auth.login.recoverPassword': 'Recuperar clave',
    'auth.login.alternativeDivider': 'O también',
    'auth.register.heroTitle': 'Únete a la red más segura.',
    'auth.register.featureGranularTitle': 'Control granular',
    'auth.register.featureGranularBody':
      'Define permisos específicos por aula, grupo o usuario individual.',
    'auth.register.featureAuditTitle': 'Auditoría completa',
    'auth.register.featureAuditBody': 'Registro inmutable de todas las acciones administrativas.',
    'auth.register.title': 'Registro institucional',
    'auth.register.subtitle': 'Crea una nueva cuenta de administrador',
    'auth.register.successLabel': '¡Bienvenido!',
    'auth.register.successBody': 'Cuenta creada correctamente. Redirigiendo al panel...',
    'auth.register.fullName': 'Nombre completo',
    'auth.register.fullNamePlaceholder': 'Tu nombre completo',
    'auth.register.corporateEmail': 'Email corporativo',
    'auth.register.role': 'Cargo',
    'auth.register.role.itDirector': 'Director de TI',
    'auth.register.role.systemsAdmin': 'Administrador de sistemas',
    'auth.register.role.academicCoordinator': 'Coordinador académico',
    'auth.register.confirmPassword': 'Confirmar',
    'auth.register.passwordMinShort': 'Mínimo 8 caracteres',
    'auth.register.termsPrefix': 'Al registrarte, aceptas nuestros ',
    'auth.register.termsLink': 'Términos de servicio',
    'auth.register.termsSuffix':
      ' y confirmas que representas a una institución educativa verificada. Los accesos externos se habilitan después de la aprobación institucional.',
    'auth.register.createAccount': 'Crear cuenta',
    'auth.register.createError': 'Error al registrar la cuenta',
    'auth.validation.passwordMismatch': 'Las contraseñas no coinciden',
    'auth.validation.passwordMin': 'La contraseña debe tener al menos 8 caracteres',
    'rules.type.whitelist.label': 'Dominio permitido',
    'rules.type.whitelist.badge': 'Permitido',
    'rules.type.whitelist.export': 'Permitido',
    'rules.type.blockedSubdomain.label': 'Subdominio bloqueado',
    'rules.type.blockedSubdomain.badge': 'Sub. bloq.',
    'rules.type.blockedSubdomain.export': 'Subdominio bloqueado',
    'rules.type.blockedPath.label': 'Ruta bloqueada',
    'rules.type.blockedPath.badge': 'Ruta bloq.',
    'rules.type.blockedPath.export': 'Ruta bloqueada',
    'rules.detect.pathReason': 'Contiene una ruta (/)',
    'rules.detect.subdomainExistingReason':
      '"{rootDomain}" ya está permitido, se bloqueará este subdominio',
    'rules.detect.wildcardExistingReason':
      'Patrón wildcard para bloquear subdominios de "{baseRoot}"',
    'rules.detect.wildcardReason': 'Patrón wildcard detectado',
    'rules.detect.whitelistReason': 'Dominio para añadir a la lista blanca',
    'rules.validation.empty': 'El valor no puede estar vacío',
    'rules.validation.domainTooShort': 'El dominio es demasiado corto (mínimo 4 caracteres)',
    'rules.validation.domainTooLong': 'El dominio excede los 253 caracteres permitidos',
    'rules.validation.domainConsecutiveDots':
      'El dominio no puede contener puntos consecutivos (..)',
    'rules.validation.domainInvalidFormat':
      'Formato de dominio inválido. Ejemplo válido: example.com',
    'rules.validation.domainLabelTooLong':
      'Cada parte del dominio debe tener como máximo 63 caracteres',
    'rules.validation.subdomainTooShort': 'El subdominio es demasiado corto (mínimo 4 caracteres)',
    'rules.validation.subdomainTooLong': 'El subdominio excede los 253 caracteres permitidos',
    'rules.validation.subdomainConsecutiveDots':
      'El subdominio no puede contener puntos consecutivos (..)',
    'rules.validation.subdomainInvalidFormat':
      'Formato de subdominio inválido. Ejemplo válido: sub.example.com o *.example.com',
    'rules.validation.subdomainLabelTooLong':
      'Cada parte del subdominio debe tener como máximo 63 caracteres',
    'rules.validation.pathMissingSlash':
      'La ruta debe contener una barra (/). Ejemplo: example.com/path',
    'rules.validation.pathEmpty': 'La ruta después del dominio no puede estar vacía',
    'rules.validation.pathInvalidChars': 'La ruta contiene caracteres no permitidos (espacios)',
    'rules.validation.pathInvalidDomain': 'Dominio inválido en la ruta: {domainError}',
    'rules.validation.invalidFormat': 'Formato inválido',
    'rules.group.status.allowed': 'Permitido',
    'rules.group.status.blocked': 'Bloqueado',
    'rules.group.status.mixed': 'Mixto',
    'rules.group.globalPaths': 'Rutas globales',
    'rules.group.selectGroup': 'Seleccionar grupo',
    'rules.group.deselectGroup': 'Deseleccionar grupo',
    'rules.group.addSubdomain': 'Añadir subdominio a {rootDomain}',
  },
} as const;

export type ProductI18nKey = keyof (typeof productI18nCatalogs)['en'];
export type ProductI18nParams = Record<string, string | number>;
export type ProductT = (key: ProductI18nKey, params?: ProductI18nParams) => string;

interface ProductI18nContextValue {
  locale: ProductLocale;
  t: ProductT;
}

const ProductI18nContext = createContext<ProductI18nContextValue | null>(null);

function isProductLocale(locale: string): locale is ProductLocale {
  return SUPPORTED_PRODUCT_LOCALES.includes(locale as ProductLocale);
}

function getBrowserLocaleCandidates(): string[] {
  if (typeof globalThis.navigator === 'undefined') {
    return [];
  }

  const languages = Array.from(globalThis.navigator.languages);
  return [globalThis.navigator.language, ...languages].filter((candidate) => candidate.length > 0);
}

export function resolveProductLocale(locale?: string | readonly string[] | null): ProductLocale {
  const candidates =
    typeof locale === 'string' ? [locale] : locale ? [...locale] : getBrowserLocaleCandidates();

  for (const candidate of candidates) {
    const normalized = candidate.trim().toLowerCase();
    const [baseLocale = ''] = normalized.split('-');
    if (isProductLocale(baseLocale)) {
      return baseLocale;
    }
  }

  return 'en';
}

function formatProductMessage(message: string, params: ProductI18nParams = {}): string {
  return message.replace(/\{([a-zA-Z0-9_]+)\}/g, (match, name: string) => {
    if (!Object.prototype.hasOwnProperty.call(params, name)) {
      return match;
    }
    return String(params[name]);
  });
}

export function translateProductText(
  locale: ProductLocale,
  key: string,
  params?: ProductI18nParams
): string {
  const catalog: Record<string, string | undefined> = productI18nCatalogs[locale];
  const message = catalog[key];

  if (message === undefined) {
    throw new Error(`Missing OpenPath i18n key "${key}" for locale "${locale}"`);
  }

  return formatProductMessage(message, params);
}

interface OpenPathI18nProviderProps {
  children: React.ReactNode;
  locale?: string | readonly string[] | null;
}

export function OpenPathI18nProvider({ children, locale }: OpenPathI18nProviderProps) {
  const resolvedLocale = resolveProductLocale(locale);
  const value = useMemo<ProductI18nContextValue>(
    () => ({
      locale: resolvedLocale,
      t: (key, params) => translateProductText(resolvedLocale, key, params),
    }),
    [resolvedLocale]
  );

  return <ProductI18nContext.Provider value={value}>{children}</ProductI18nContext.Provider>;
}

export function useOpenPathI18n(): ProductI18nContextValue {
  const value = useContext(ProductI18nContext);
  if (value) {
    return value;
  }

  const locale = resolveProductLocale();
  return {
    locale,
    t: (key, params) => translateProductText(locale, key, params),
  };
}

export function useT(): ProductT {
  return useOpenPathI18n().t;
}
