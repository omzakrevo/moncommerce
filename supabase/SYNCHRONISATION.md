# Boutique unique et synchronisation

Le compte Supabase (auth.users.id) identifie la boutique. La connexion lit
profiles.shop_name sans le remplacer. L'inscription est désormais explicite.

## Activation serveur

Projet cible : vcmisyzfoermqcvmszpa. Migration owner_shop_snapshots_sync appliquée
le 26 septembre 2026. Les essais SQL ont validé les révisions et l'isolation entre
comptes dans une transaction annulée. Aucun produit réel n'a été modifié.

Procédure de vérification et de livraison :

1. Reconnecter le compte Supabase propriétaire du projet cible.
2. Inspecter profiles (clé primaire id), ses règles RLS et les déclencheurs
   d'inscription ; confirmer qu'un compte possède un seul profil.
3. Appliquer setup_shop_sync.sql comme migration additive sur ce projet.
4. Vérifier les droits avec deux utilisateurs différents : lecture et écriture
   uniquement de leur propre snapshot, rejet d'une révision périmée. Faire ces
   essais dans une transaction annulée ou avec des comptes de test dédiés.
5. Exécuter les conseillers de sécurité Supabase, puis un essai réel entre deux
   sessions du même propriétaire. Tester aussi les modifications hors ligne.
6. Compiler Windows et Android. L'APK de mise à jour de l'ancienne distribution
   doit conserver son certificat Android Debug historique ; le certificat
   MonCommerce utilisé pour un autre APK n'est pas interchangeable.

## Données et protection

shop_snapshots contient les produits, ventes, crédits, dépenses, documents
commerciaux, fournisseurs et paramètres partagés. Une ligne par propriétaire,
RLS et contrôle optimiste de révision protègent les mises à jour.

Un nouvel appareil vide récupère le snapshot existant ; il n'envoie pas une
boutique vide. Si le snapshot n'existe pas encore, le catalogue store_products
est récupéré pour amorcer les produits déjà publiés par les anciennes versions.
Les prix d'achat et codes-barres absents de cet ancien catalogue devront être
envoyés depuis l'appareil d'origine, qui possède les données complètes.

Deux modifications concurrentes divergentes suspendent la synchronisation,
conservent les données locales et une copie distante. Aucun écrasement
automatique n'est fait. Le bouton Résoudre permet d'exporter les deux copies et
de choisir explicitement la version à conserver. Une sauvegarde locale des deux
versions précède chaque remplacement.

Les paramètres sont isolés entre propriétaires. Les réglages d'imprimante et
les comptes de personnel hors ligne restent propres à chaque installation.
Une connexion Internet est nécessaire pour transférer des changements.

Les anciennes versions ne lisent pas ces snapshots : mettre à jour les deux
appareils, puis ouvrir d'abord l'appareil qui contient les données complètes.
