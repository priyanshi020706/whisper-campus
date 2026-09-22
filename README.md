# Whisper Campus

> A verified and anonymous campus communication platform built for secure, private, and meaningful student communities.

## 📌 About

Whisper Campus is a college-restricted communication platform designed to give students a space to communicate anonymously while maintaining verification, privacy, and accountability.

The platform is built around four principles:

- **VERIFIED** — Only authorized college members can access the platform.
- **ANONYMOUS** — Students interact through anonymous identities.
- **USEFUL** — Communication is organized around campus communities and topics.
- **ACCOUNTABLE** — Safety mechanisms and controlled administrative access help prevent misuse.

---

## 🎯 Current Progress

### Phase 1 — Foundation ✅

- [x] Flutter project setup
- [x] Supabase integration
- [x] College-domain authentication
- [x] Magic-link authentication
- [x] Anonymous profile creation
- [x] Profile data model
- [x] Authentication gate
- [x] Row Level Security (RLS)
- [x] Protected identity records
- [x] Modular project structure
- [x] GitHub repository setup

### Upcoming

- [ ] Campus rooms
- [ ] Real-time messaging
- [ ] Anonymous posts
- [ ] Reactions and voting
- [ ] Reporting system
- [ ] AI moderation
- [ ] Strike system
- [ ] Notifications
- [ ] Administrative moderation
- [ ] Emergency identity access with audit logging

---

## 🏗️ Architecture

```text
                    ┌─────────────────────┐
                    │    Flutter Client   │
                    │                     │
                    │  Authentication     │
                    │  Anonymous Profile  │
                    │  Campus Features    │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │       Supabase      │
                    │                     │
                    │  Authentication     │
                    │  PostgreSQL         │
                    │  Row Level Security │
                    │  Realtime           │
                    └──────────┬──────────┘
                               │
                               ▼
                    ┌─────────────────────┐
                    │    Protected Data   │
                    │                     │
                    │ Anonymous Profiles  │
                    │ Identity Records    │
                    │ Campus Data         │
                    └─────────────────────┘
```
### Anonymous Identity Model

Whisper Campus separates a student's real identity from the identity visible to other students.

```text

Real Identity
      │
      ▼
Internal User ID
      │
      ▼
Anonymous Identity
      │
      ▼
Campus Interaction
```

## Privacy & Security
Whisper Campus is designed around the principle:

Anonymous to other students, but accountable to a controlled safety system.

Current security measures include:

- College-domain restriction
- Supabase Authentication
- Row Level Security (RLS)
- Protected identity records
- Separation of identity and anonymous profile data
- Backend-controlled authorization
- No exposure of real identity fields to normal users

Future safety mechanisms include reporting, moderation, strikes, audit logging, and controlled emergency identity access.

## Tech Stack
Frontend
- Flutter
- Dart

Backend & Database
- Supabase
- PostgreSQL
- Supabase Auth
- Row Level Security

Planned Technologies
- Realtime communication
- AI-based moderation
- Push notifications
- Media storage
- Administrative moderation tools

## Project Structure
lib/
├── core/
│   └── constants/
│       └── app_constants.dart
│
├── models/
│   └── profile_model.dart
│
├── services/
│   └── auth_service.dart
│
├── pages/
│   ├── auth/
│   │   ├── auth_gate.dart
│   │   └── sign_up_page.dart
│   │
│   └── profile/
│       └── profile_page.dart
│
└── main.dart

The project follows a modular structure so new features can be added without keeping the entire application inside a single file.

## Getting Started
Prerequisites
- Flutter SDK
- Dart SDK
- Android Studio / VS Code
- A Supabase project

## Installation
1. Clone the repository

2. Navigate into the Project: 
> `cd whisper-campus`

3. Install dependencies:
> `flutter pub get`

4. Run the application:
> `flutter run`

##  Development Roadmap
Phase 1
Foundation
   ↓
Phase 2
Communication
   ↓
Phase 3
Social Content
   ↓
Phase 4
Safety & Moderation
   ↓
Phase 5
Administration
   ↓
Phase 6
Production Hardening

## Team
Whisper Campus is being developed as a collaborative student project.

The team is building the system incrementally, starting with authentication and privacy foundations before implementing communication and moderation features.

## Project Status
**Current Stage:** Foundation / Authentication & Profile

The project is under active development.
