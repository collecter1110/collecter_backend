 # **Collecter_backend**

This repository contains a backend solution built with Supabase, designed to provide real-time database capabilities, authentication, and storage services. It leverages Supabase’s powerful features to deliver a scalable and efficient backend for cross-platform applications.

<br>

## **How to Clone and Run**

### **Clone the Repository**
```bash
git clone https://github.com/collecter1110/collecter_backend.git
cd supabase
```
<br>

## **File Structure**
```
.
├── .github
│   ├── components          # Reusable UI components
│   ├── data                # Data processing
│   │   ├── model           # Classify imported data
│   │   ├── provider        # Provider management
│   │   └── services        # Data-related modular logic management
│   ├── page                # Page
│   ├── main                # main.dart
│   └── page_navigator      # Page movement and rendering
└── supabase                  # Static assets (images, fonts, etc.)
    ├── icons               # icon with function
    └── images              # Image without features



```

<br>

## **Branching Strategy**

We use the **Git Flow** branching model:

- `main`: Contains the latest production-ready code. This branch is only updated when the application is ready for deployment or an app update is scheduled.
- `dev`: Serves as the integration branch for ongoing development. All new features and fixes are merged into this branch.
- `Feature branches`: Named as `feature/feature-name`. Development for individual features or fixes happens in these branches. Once completed, they are merged into dev.
- Deployment process: The administrator merges dev into main when the application is ready for production deployment or updates.

<br>
  
## **Commit Message Guidelines**

### **Commit format:**

[TYPE] : [Short description]

[Body] : [Notion Link and Task ID]


### **Types:**

- `feat`: A new feature
- `fix`: A bug fix
- `docs`: Documentation changes
- `style`: Code style changes (formatting, missing semi-colons, etc.)
- `refactor`: Code refactoring without adding new features or fixing bugs
- `test`: Adding or updating tests
- `chore`: Maintenance tasks


