// Копія цього файла має називатися config.js і лежати поруч із index.html.
// Обидва значення беруться з Supabase → Project Settings → API Keys.
//
// Ключ publishable публічний за призначенням: він лише каже, до якого проєкту
// звертатись. Доступ до даних вирішують політики в базі, а не таємність ключа.
// Ключі secret / service_role сюди класти НЕ МОЖНА ніколи.
window.FB_CONFIG = {
  url: 'https://ВАШ-ПРОЄКТ.supabase.co',
  anonKey: 'sb_publishable_ВАШ-КЛЮЧ',
};
