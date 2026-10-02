using ContractWorkflow.Api.Data;
using ContractWorkflow.Api.Models;
using Microsoft.Data.SqlClient;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton<ContractRepository>();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var app = builder.Build();
app.UseSwagger();
app.UseSwaggerUI();

// 1) Global error handling: SQL business errors -> proper HTTP codes, anything else -> logged 500
app.Use(async (ctx, next) =>
{
    try
    {
        await next();
    }
    catch (SqlException ex) when (ex.Number is 50001 or 50002 or 50003)
    {
        ctx.Response.StatusCode = ex.Number switch { 50001 => 400, 50002 => 404, _ => 409 };
        await ctx.Response.WriteAsJsonAsync(new { error = ex.Message });
    }
    catch (Exception ex)
    {
        var repo = ctx.RequestServices.GetRequiredService<ContractRepository>();
        try { await repo.LogAsync("API", ctx.Request.Path.Value, 500, "ERROR", ex.Message); } catch { /* never mask the original error */ }
        ctx.Response.StatusCode = 500;
        await ctx.Response.WriteAsJsonAsync(new { error = "Internal server error" });
    }
});

// 2) API key check for /api/* (Power Automate sends this in the X-Api-Key header)
app.Use(async (ctx, next) =>
{
    if (ctx.Request.Path.StartsWithSegments("/api"))
    {
        var expected = app.Configuration["ApiKey"];
        var provided = ctx.Request.Headers["X-Api-Key"].ToString();
        if (string.IsNullOrEmpty(expected) || provided != expected)
        {
            ctx.Response.StatusCode = 401;
            await ctx.Response.WriteAsJsonAsync(new { error = "Invalid or missing API key" });
            return;
        }
    }
    await next();
});

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

// Create a contract (called when a new SharePoint item is created). Idempotent on SharePointItemId.
app.MapPost("/api/contracts", async (CreateContractRequest req, ContractRepository repo) =>
{
    if (string.IsNullOrWhiteSpace(req.Title) || string.IsNullOrWhiteSpace(req.Counterparty) ||
        string.IsNullOrWhiteSpace(req.ContractType) || string.IsNullOrWhiteSpace(req.SubmittedBy))
        return Results.BadRequest(new { error = "Title, Counterparty, ContractType and SubmittedBy are required." });

    var result = await repo.CreateAsync(req);
    await repo.LogAsync("API", "POST /api/contracts", result.AlreadyExisted ? 200 : 201, "INFO",
        $"Contract {result.ContractId} {(result.AlreadyExisted ? "already existed (retry)" : "created")}.");

    return result.AlreadyExisted
        ? Results.Ok(result)
        : Results.Created($"/api/contracts/{result.ContractId}", result);
});

// Record the approval outcome (called by Power Automate after the Approval action)
app.MapPost("/api/contracts/{id:int}/decision", async (int id, DecisionRequest req, ContractRepository repo) =>
{
    // Power Automate returns "Approve"/"Reject"; normalise to what the DB expects.
    var decision = req.Decision?.Trim().ToLowerInvariant() switch
    {
        "approve" or "approved" => "Approved",
        "reject" or "rejected" => "Rejected",
        _ => null
    };
    if (decision is null)
        return Results.BadRequest(new { error = "Decision must be Approve/Approved or Reject/Rejected." });
    if (string.IsNullOrWhiteSpace(req.ActedBy))
        return Results.BadRequest(new { error = "ActedBy is required." });

    await repo.RecordDecisionAsync(id, decision, req.ActedBy, req.Comments);
    await repo.LogAsync("API", $"POST /api/contracts/{id}/decision", 204, "INFO", $"Contract {id} -> {decision} by {req.ActedBy}.");
    return Results.NoContent();
});

app.MapGet("/api/contracts", async (string? status, ContractRepository repo) =>
    Results.Ok(await repo.GetAsync(status)));

app.MapGet("/api/contracts/{id:int}", async (int id, ContractRepository repo) =>
{
    var all = await repo.GetAsync(null);
    var item = all.FirstOrDefault(c => c.ContractId == id);
    return item is null ? Results.NotFound(new { error = "Contract not found." }) : Results.Ok(item);
});

app.Run();
