Faisons un script PowerShell interactif à exécuter en mode Administrateur et qui permettrait de gérer les interfaces réseau sur un système Windows. Le script permettra à l'utilisateur de lister les interfaces réseau disponibles, d'activer ou de désactiver une interface spécifique, et de configurer les paramètres IP.

1. Liste des interfaces réseau disponibles, avec leur nom, état (activée/désactivée), et adresse IP actuelle.
2. Quelle interface voulez-vous modifier ? Entrez le numéro correspondant à l'interface que vous souhaitez gérer. (ou mieux encore, menu dans lequel on peut sélectionner l'interface à l'aide des touches fléchées et Entrée)
3. Voulez-vous activer ou désactiver cette interface ? n/Y si interface est activée, y/N si elle est désactivée.
4. Voulez-vous configurer activer l'interface en mode DHCP ou définir une adresse IP statique ? (Entrez 'D' pour activer le DHCP ou 'S' pour définir une IP statique)
5. Si vous choisissez de définir une IP statique, entrez l'adresse IP et le masque de sous-réseau au format CIDR.
6. Ajouter une adresse IP supplémentaire ?
7. Ajouter une passerelle par défaut ?
8. Ajouter un serveur DNS primaire et secondaire ? (aller à ce menu directement si vous avez choisi de configurer une IP DHCP)
9. Afficher un résumé des modifications apportées et demander confirmation avant de les appliquer.
10. Retour au menu principal ou quitter le script.

Pour toutes les étapes, le paramètre actuellement en cours est affiché. Si l'utilisateur fais Entrée sans entrer de valeur, le script conservera la valeur actuelle.

Faire un bel écran d'accueil en ASCII art qui affiche "Gestionnaire d'Interfaces Réseau" et un message de bienvenue.

Fais-moi un plan d'action et donne tes suggestions pour la mise en oeuvre et les différents menus/sous-menus.