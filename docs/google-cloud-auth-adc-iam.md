# Authentification Google Cloud : ADC et impersonation IAM

> Documentation technique anonymisée — démonstrateur Angular / BFF NestJS / API de management Apigee X.  
> Version documentaire : 1.0 — novembre 2026.  
> **Portée : exemple d'architecture et retour d'expérience non spécifique à une organisation.** Les identités, routes, domaines, namespaces et configurations sont fictifs ou génériques.

## 1. Objectif et périmètre

Une application Angular consulte un backend-for-frontend (BFF) NestJS, qui interroge des API de management Apigee X. Les accès à Google Cloud sont effectués **par le serveur**, sans transmettre de clé privée ni de token Google technique au navigateur.

Deux méthodes ont été examinées :

| Méthode | Objectif | État de validation |
| --- | --- | --- |
| **V1 — Application Default Credentials (ADC)** | Identifier directement le workload du BFF auprès de Google Cloud | **Validée** en local et dans un environnement Kubernetes/OpenShift de développement, avec parcours frontend → BFF → API |
| **V2 — Impersonation IAM Credentials** | Obtenir un access token au nom d'un compte de service cible, sans posséder sa clé privée | **Test CLI validé** avec une identité utilisateur ; intégration NestJS et exécution non interactive en cluster **non validées** |

**Important :** les deux méthodes émettent des tokens OAuth 2.0 temporaires. « Token éphémère » n'est pas une propriété exclusive de l'impersonation IAM.

### Architecture commune

~~~mermaid
flowchart TB
    U[Utilisateur / Navigateur] --> A[Application Angular]
    A -->|Requêtes HTTP vers le BFF| B[BFF NestJS]
    B -->|Google Auth Library / OAuth 2.0| G[Google Cloud]
    G -->|Access token temporaire| B
    B -->|Authorization: Bearer access_token| X[Apigee X Management API]
~~~

La gestion de l'identité **des utilisateurs du portail** (SSO/OIDC et autorisations) est un sujet distinct de l'authentification **technique BFF → Google Cloud**. Un BFF qui accède à Apigee avec une identité partagée doit vérifier les droits des utilisateurs avant de servir des données sensibles.

## 2. Interfaces BFF considérées

Exemple de routes REST exposées par le BFF :

| Requête côté Angular | Requête cible côté Apigee |
| --- | --- |
| GET /api/apigee/apis | GET /apis |
| GET /api/apigee/developers | GET /developers?expand=true |
| GET /api/apigee/apps | GET /apps?expand=true |
| GET /api/apigee/apiproducts | GET /apiproducts?expand=true |

Les chemins sont donnés comme **exemples**. Certaines réponses de gestion des applications peuvent contenir des informations de credentials : elles ne doivent pas être retransmises sans filtrage et autorisation.

## 3. Méthode V1 — Application Default Credentials

### 3.1 Principe

**ADC est une stratégie de découverte de credentials**, pas un grant OAuth autonome. Lorsque aucun credential explicite n'est transmis, la bibliothèque Google recherche principalement :

1. Le fichier désigné par la variable **GOOGLE_APPLICATION_CREDENTIALS**.
2. Les credentials ADC utilisateur créés localement par Google Cloud CLI.
3. Une identité associée à un environnement Google Cloud compatible, via le serveur de métadonnées.

Dans le scénario illustré, le fichier ADC contient les credentials d'un **compte de service**. La bibliothèque peut utiliser une assertion JWT signée pour demander un access token OAuth 2.0 à Google. Le BFF présente ensuite cet access token à l'API Apigee.

### 3.2 Prérequis

- Un compte de service Google Cloud disposant des **permissions Apigee minimales** nécessaires.
- Un mécanisme de credentials approuvé. Dans ce scénario de démonstration, un fichier JSON de compte de service est utilisé.
- Les accès HTTPS nécessaires aux endpoints de token OAuth et à l'API de management Apigee.
- Une configuration runtime correcte pour l'URL Apigee, l'organisation et le port.
- En Kubernetes/OpenShift, un mécanisme sécurisé de fourniture des credentials (Secret monté en lecture seule pour l'exemple), conformément aux règles de sécurité applicables.
- Le cas échéant, un proxy sortant approuvé et sa chaîne de certificats de confiance.

**Sécurité :** les clés de compte de service sont des secrets de longue durée. En exploitation, privilégier une identité sans clé persistante (par exemple via une fédération de workload) lorsque l'infrastructure le permet.

### 3.3 Diagramme de séquence ADC

~~~mermaid
sequenceDiagram
    participant Angular
    participant BFF as BFF NestJS
    participant ADC as GoogleAuth / ADC
    participant OAuth as Google OAuth Token Endpoint
    participant Apigee as Apigee X

    Angular->>BFF: GET /api/apigee/apis
    BFF->>ADC: getClient() puis getAccessToken()
    ADC->>ADC: Découvre des credentials de compte de service
    ADC->>OAuth: Assertion JWT signée (si credentials JSON)
    OAuth-->>ADC: Access token OAuth 2.0
    ADC-->>BFF: Access token
    BFF->>Apigee: GET /apis + Bearer token
    Apigee-->>BFF: Réponse JSON
    BFF-->>Angular: Réponse filtrée / autorisée
~~~

### 3.4 Exemple d'implémentation NestJS

~~~typescript
import { Injectable } from '@nestjs/common';
import { GoogleAuth } from 'google-auth-library';

export interface TokenProvider {
  getAccessToken(): Promise<string>;
}

@Injectable()
export class AdcTokenProvider implements TokenProvider {
  private readonly auth = new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });

  async getAccessToken(): Promise<string> {
    const client = await this.auth.getClient();
    const result = await client.getAccessToken();

    if (!result.token) {
      throw new Error('Google access token indisponible');
    }
    return result.token;
  }
}
~~~

Le service d'intégration utilise ensuite le token côté serveur, par exemple dans l'en-tête **Authorization: Bearer** d'une requête sortante. Le token ne doit **jamais** être exposé au frontend ou écrit dans les logs.

### 3.5 Exemple de configuration Kubernetes/OpenShift

ConfigMap de valeurs **non sensibles** :

~~~yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: sample-bff-config
data:
  GOOGLE_AUTH_MODE: "adc"
  APIGEE_BASE_URL: "https://REGIONAL_APIGEE_ENDPOINT/v1/organizations"
  APIGEE_ORGANIZATION: "EXAMPLE_ORG"
  PORT: "8080"
  CORS_ORIGINS: "https://frontend.example.invalid"
  HTTPS_PROXY: "http://APPROVED_PROXY:PORT"
  HTTP_PROXY: "http://APPROVED_PROXY:PORT"
  NO_PROXY: "localhost,127.0.0.1,.svc,.cluster.local"
~~~

Les adresses ci-dessus sont des **placeholders** ; ne pas les utiliser telles quelles. Les détails du proxy ne doivent pas contenir d'identifiants dans le ConfigMap.

Fragment du Deployment, à fusionner avec son manifeste existant :

~~~yaml
spec:
  template:
    spec:
      containers:
        - name: bff
          envFrom:
            - configMapRef:
                name: sample-bff-config
          env:
            - name: GOOGLE_APPLICATION_CREDENTIALS
              value: /var/run/secrets/google/credentials.json
          volumeMounts:
            - name: google-credentials
              mountPath: /var/run/secrets/google
              readOnly: true
      volumes:
        - name: google-credentials
          secret:
            secretName: sample-google-credentials
~~~

Le Secret **existe séparément** et n'est pas reproduit ici. Ne committer ni clé privée, ni fichier JSON de service account, ni access token. Les manifestes gérés par la chaîne de déploiement doivent conserver les références ConfigMap et Secret.

Les valeurs injectées via **envFrom** sont lues au démarrage du pod : modifier un ConfigMap ne met pas automatiquement à jour les variables d'un processus déjà lancé. Un nouveau rollout est nécessaire.

### 3.6 Tests réalisés pour V1

| Test / diagnostic | Observation |
| --- | --- |
| Appel local du BFF vers l'API Apigee | **Réussi** après configuration d'une sortie HTTPS adaptée |
| Construction de l'artefact et déploiement en DEV | **Réussis** |
| Démarrage du pod | **Réussi** après ajout des paramètres d'environnement obligatoires |
| Obtention du token ADC en cluster | **Réussie** après correction du chemin réseau sortant |
| Angular DEV → BFF DEV → API Apigee | **Réussi** après correction CORS et redémarrage du pod |
| Validation sécurité pour un usage multi-utilisateur | **Non couverte** par ces tests techniques |

Principaux incidents de validation et enseignements :

- **CrashLoopBackOff** : absence de variables applicatives obligatoires ; corriger la configuration runtime, pas le mécanisme ADC.
- **Timeout HTTP 504** : absence de connectivité sortante HTTPS ; vérifier la résolution DNS, le proxy approuvé et la politique réseau.
- **CORS / HTTP 0 dans le navigateur** : absence d'origine autorisée dans les headers de réponse ; contrôler la valeur réelle de la variable dans le pod et redémarrer après modification du ConfigMap.

## 4. Méthode V2 — Impersonation de compte de service avec IAM Credentials

### 4.1 Principe et identités

Deux identités interviennent :

- **Source** : utilisateur, compte de service ou workload déjà authentifié, disposant du droit de demander un token pour la cible.
- **Cible** : compte de service dont Google IAM Credentials génère l'access token. Les appels à Apigee sont exécutés **avec les permissions de cette cible**.

L'identité source doit disposer de **iam.serviceAccounts.getAccessToken** sur la cible. Le rôle prédéfini **roles/iam.serviceAccountTokenCreator** fournit cette permission, mais peut accorder d'autres capacités : limiter sa portée et préférer une autorisation minimale lorsque possible.

Le compte cible n'a **pas besoin de fournir sa clé privée** au demandeur.

### 4.2 Prérequis

- Une identité source Google Cloud authentifiée et autorisée.
- Un compte de service cible muni des permissions API nécessaires.
- La permission **iam.serviceAccounts.getAccessToken** sur la cible pour l'identité source.
- L'activation de **IAM Service Account Credentials API** dans le projet applicable.
- L'accès HTTPS aux services d'authentification Google et à **iamcredentials.googleapis.com**.
- Pour un pod en cluster : une **identité non interactive** de workload autorisée, distincte d'une simple session CLI humaine.

### 4.3 Diagramme de séquence IAM

~~~mermaid
sequenceDiagram
    participant BFF as BFF / Client
    participant Source as Identité source
    participant IAM as IAM Credentials API
    participant Apigee as Apigee X

    BFF->>Source: Obtenir un credential source valide
    Source-->>BFF: Credential / client authentifié
    BFF->>IAM: generateAccessToken(compte cible, scopes)
    IAM->>IAM: Vérifie getAccessToken sur la cible
    IAM-->>BFF: Access token temporaire du compte cible
    BFF->>Apigee: Requête avec le token de la cible
    Apigee-->>BFF: Réponse selon les droits de la cible
~~~

### 4.4 Test CLI réalisé — validé

Dans un environnement autorisé disposant de Google Cloud CLI :

~~~bash
# Authentification du compte utilisateur pour la CLI, si nécessaire
gcloud auth login

# Contrôle du compte actif
gcloud auth list

# Test de génération d'un token pour le compte cible
gcloud auth print-access-token \
  --impersonate-service-account="TARGET_SERVICE_ACCOUNT@PROJECT_ID.iam.gserviceaccount.com"
~~~

**Résultat confirmé :** un access token éphémère a pu être généré via la CLI avec impersonation d'un compte de service cible.

Ne pas publier la sortie de cette commande : elle constitue un credential utilisable jusqu'à son expiration.

**Limite du test :** une authentification effectuée avec **gcloud auth login** ne crée pas automatiquement les Application Default Credentials utilisés par la bibliothèque NestJS. La réussite du test CLI **ne prouve pas** le fonctionnement du BFF dans un pod.

### 4.5 Exemple d'implémentation NestJS à valider

~~~typescript
import { Injectable } from '@nestjs/common';
import { GoogleAuth, Impersonated } from 'google-auth-library';

@Injectable()
export class IamTokenProvider implements TokenProvider {
  private readonly auth = new GoogleAuth({
    scopes: ['https://www.googleapis.com/auth/cloud-platform'],
  });

  private client?: Impersonated;

  async getAccessToken(): Promise<string> {
    if (!this.client) {
      const targetPrincipal = process.env.GOOGLE_TARGET_SERVICE_ACCOUNT;
      if (!targetPrincipal) {
        throw new Error('Compte de service cible IAM non configuré');
      }

      const sourceClient = await this.auth.getClient();
      this.client = new Impersonated({
        sourceClient,
        targetPrincipal,
        targetScopes: ['https://www.googleapis.com/auth/cloud-platform'],
        lifetime: 3600,
        delegates: [],
      });
    }

    const result = await this.client.getAccessToken();
    if (!result.token) {
      throw new Error('Access token IAM indisponible');
    }
    return result.token;
  }
}
~~~

L'extrait suppose que l'interface **TokenProvider** est importée depuis le module d'authentification. Dans un projet NestJS utilisant des decorators, importer le type d'interface séparément si nécessaire.

**Distinction importante :** IamTokenProvider **n'appelle pas** AdcTokenProvider. Il construit son propre **GoogleAuth**, qui peut utiliser la découverte ADC pour obtenir l'identité source. L'objet **Impersonated** déclenche ensuite l'appel IAM Credentials.

### 4.6 Travaux restant pour V2

1. Choisir et configurer une identité technique **non interactive** pour le workload en cluster (fédération d'identité ou autre mécanisme approuvé).
2. Accorder à cette identité le droit d'impersoner le compte cible sur le périmètre strictement nécessaire.
3. Vérifier la connectivité à IAM Credentials.
4. Valider les appels de **IamTokenProvider** depuis NestJS, puis depuis le cluster.
5. Vérifier les mêmes opérations fonctionnelles du BFF et publier une release V2 distincte.

**Statut : non validé de bout en bout.**

## 5. Synthèse comparative

| Critère | V1 ADC avec compte de service JSON | V2 IAM impersonation |
| --- | --- | --- |
| Identité utilisée par l'API cible | Compte du fichier JSON | Compte de service cible impersoné |
| Identité initiale | Credentials de compte de service | Compte utilisateur, service ou workload |
| Access token temporaire | Oui | Oui |
| Clé privée du compte cible dans le BFF | Présente dans le scénario JSON | Non nécessaire |
| API IAM Credentials appelée | Non pour ce flux de base | Oui |
| Autorisation principale | Permissions Apigee du compte de service | Permission d'impersonation de la source + permissions Apigee de la cible |
| Validation | Local + DEV + intégration navigateur | Commande gcloud uniquement |

## 6. Sécurité et exploitation — points ouverts

- Ne pas confondre **authentification technique du BFF** et **authentification utilisateur du portail**.
- Imposer authentification, autorisation par ressource et contrôle d'accès aux données sensibles avant une ouverture multi-utilisateurs.
- Ne jamais versionner de clés de service, tokens, URLs internes sensibles, secrets de proxy ou configurations propres à une organisation.
- Appliquer le moindre privilège aux comptes de service et à l'identité autorisée à impersoner.
- Gérer les certificats TLS et les sorties réseau via les mécanismes approuvés.
- Évaluer la fédération d'identité pour éviter des clés privées longues durées dans les conteneurs.
- Soumettre l'image runtime Node.js à un contrôle de vulnérabilités ; une application fonctionnelle ne signifie pas que son image de base est corrigée.
- Les illustrations et valeurs dans ce document sont **volontairement fictives**.

## 7. Références officielles

- [Google Cloud — How Application Default Credentials works](https://cloud.google.com/docs/authentication/application-default-credentials)
- [Google Cloud — Service account impersonation](https://cloud.google.com/docs/authentication/use-service-account-impersonation)
- [Google Cloud — Service account permissions](https://cloud.google.com/iam/docs/service-account-permissions)
- [Google Cloud — IAM Credentials generateAccessToken](https://cloud.google.com/iam/docs/reference/credentials/rest/v1/projects.serviceAccounts/generateAccessToken)
- [Kubernetes — ConfigMaps](https://kubernetes.io/docs/concepts/configuration/configmap/)
- [Kubernetes — Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

---

*Ce document décrit un exercice technique anonymisé. Il ne constitue ni une configuration de production prête à déployer ni une attestation de conformité de sécurité.*
