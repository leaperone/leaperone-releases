# Vibeface app deployment

`deploy-vibeface-app` receives an exact stable app tag and source commit from the Vibeface release workflow.
It deploys the published static component to the existing Nginx document root and checks the public HTTP entry points.

Deployment credentials and destination paths come from repository Secrets. No infrastructure values belong in this repository.
