# Contract Approval Workflow

A contract-lifecycle style integration: **SharePoint list -> Power Automate approval -> .NET API -> SQL Server**.
Built to practise enterprise integration patterns: REST APIs, approval flows, stored procedures,
idempotent retries, and an integration log for debugging pipeline failures.

## Architecture

```
SharePoint List (Contracts)
        |  item created
        v
Power Automate flow
   1. HTTP POST  /api/contracts                 (register contract)
   2. Start and wait for an approval            (manager approves/rejects)
   3. HTTP POST  /api/contracts/{id}/decision   (record outcome)
   4. Update SharePoint item Status
   On any failure -> failure branch -> POST to API log / notify owner
        |
        v
ASP.NET Core Web API (C#, Dapper)  -- X-Api-Key auth
        |  stored procedures only
        v
SQL Server: Contracts, ApprovalHistory, IntegrationLog
```

## Key design decisions
- **Idempotency:** a unique filtered index on `SharePointItemId` plus `usp_CreateContract` means a retried Power Automate run never creates duplicates.
- **Transactions + validation in stored procedures:** a decision can't be applied twice; errors use `THROW` codes (50001-50003) that the API maps to 400/404/409.
- **Integration log:** every API call and every failure is written to `IntegrationLog` so stuck or failed items can be traced with plain SQL (see the debugging queries at the bottom of `sql/01_schema.sql`).
- **Auth:** API key in `X-Api-Key` header (keep the real key in an environment variable / Power Automate secure input).
- **Power Automate outcome mapping:** the API accepts `Approve`/`Reject` (what Power Automate returns) and normalises to `Approved`/`Rejected`.

## Run locally

1. **SQL Server** - install SQL Server Developer, or run `docker compose up -d`.
2. Run `sql/01_schema.sql` (SSMS, Azure Data Studio, or VS Code mssql extension).
3. Set your connection string and API key in `src/ContractWorkflow.Api/appsettings.json`
   (or env vars `ConnectionStrings__Default` and `ApiKey`).
4. ```
   cd src/ContractWorkflow.Api
   dotnet run
   ```
5. Open `http://localhost:<port>/swagger` and test. Every `/api/*` call needs header `X-Api-Key`.

### Quick test (curl)
```
curl -X POST http://localhost:5000/api/contracts \
  -H "Content-Type: application/json" -H "X-Api-Key: change-me-before-deploying" \
  -d '{"title":"Vendor NDA","counterparty":"Acme Ltd","contractType":"NDA","contractValue":0,"sharePointItemId":101,"submittedBy":"user@example.com"}'

curl -X POST http://localhost:5000/api/contracts/1/decision \
  -H "Content-Type: application/json" -H "X-Api-Key: change-me-before-deploying" \
  -d '{"decision":"Approve","actedBy":"manager@example.com","comments":"OK"}'
```

## SharePoint setup
Create a list named **Contracts** with columns: Title (default), Counterparty (text),
ContractType (choice: NDA, MSA, SOW, Vendor), ContractValue (number),
Status (choice: Submitted, InReview, Approved, Rejected; default Submitted), ContractId (number, filled by the flow).

## Power Automate flow (automated cloud flow)
1. **Trigger:** SharePoint - *When an item is created* (site + Contracts list).
2. **HTTP** - POST `<your API URL>/api/contracts`, headers `Content-Type: application/json` and `X-Api-Key`,
   body built from the item's fields (`sharePointItemId` = item ID, `submittedBy` = Created By email).
3. **Parse JSON** on the response to get `contractId`.
4. **Update item** - set Status = InReview, ContractId = parsed value.
5. **Start and wait for an approval** - Approve/Reject, assigned to a manager.
6. **HTTP** - POST `<API URL>/api/contracts/{contractId}/decision` with `decision` = approval outcome,
   `actedBy` = responder email, `comments` = responder comments.
7. **Update item** - Status = Approved / Rejected.
8. **Failure handling:** put steps 2 and 6 in a Scope, add a parallel branch *Configure run after = has failed*
   that sends an email/Teams message with the error and the item link. Set a retry policy on the HTTP actions.

> The HTTP action is a premium connector. Power Automate cannot reach `localhost`: expose the API with a
> dev tunnel / ngrok, or deploy the Dockerfile (e.g. on Render).

## Debugging scenarios to describe in interviews
- Flow succeeded in Power Automate but SQL shows no row -> check `IntegrationLog` for `ERROR` entries.
- Duplicate-looking runs -> idempotent create returns `AlreadyExisted = 1` instead of duplicating.
- Item stuck in review -> "stuck > 2 days" query in `sql/01_schema.sql`.

## Tech
C# / .NET 8, ASP.NET Core minimal APIs, Dapper, SQL Server (T-SQL stored procedures), SharePoint, Power Automate, Docker.
