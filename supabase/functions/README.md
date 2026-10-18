# Notifications de mise à jour

Cette fonction envoie une notification Firebase à tous les appareils abonnés au sujet `all_users` après la publication d'une mise à jour depuis MonCommerce.

Configurez ces secrets dans Supabase : `FCM_PROJECT_ID`, `FCM_CLIENT_EMAIL` et `FCM_PRIVATE_KEY`. Ils proviennent d'un compte de service Firebase autorisé à utiliser Firebase Cloud Messaging.

Déployez ensuite la fonction :

```powershell
supabase functions deploy send-update-notification
```

La fonction vérifie que l'appelant est super administrateur avant d'envoyer la notification.
