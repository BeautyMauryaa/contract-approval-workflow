using ContractWorkflow.Api.Models;
using Dapper;
using Microsoft.Data.SqlClient;
using System.Data;

namespace ContractWorkflow.Api.Data;

/// <summary>All database access goes through stored procedures (no inline SQL in the API).</summary>
public class ContractRepository
{
    private readonly string _connectionString;

    public ContractRepository(IConfiguration config)
    {
        _connectionString = config.GetConnectionString("Default")
            ?? throw new InvalidOperationException("Connection string 'Default' is missing.");
    }

    private SqlConnection CreateConnection() => new(_connectionString);

    public async Task<CreateResult> CreateAsync(CreateContractRequest r)
    {
        using var db = CreateConnection();
        return await db.QueryFirstAsync<CreateResult>(
            "dbo.usp_CreateContract",
            new
            {
                Title = r.Title,
                Counterparty = r.Counterparty,
                ContractType = r.ContractType,
                ContractValue = r.ContractValue,
                SharePointItemId = r.SharePointItemId,
                SubmittedBy = r.SubmittedBy
            },
            commandType: CommandType.StoredProcedure);
    }

    public async Task RecordDecisionAsync(int contractId, string decision, string actedBy, string? comments)
    {
        using var db = CreateConnection();
        await db.ExecuteAsync(
            "dbo.usp_RecordDecision",
            new { ContractId = contractId, Decision = decision, ActedBy = actedBy, Comments = comments },
            commandType: CommandType.StoredProcedure);
    }

    public async Task<IEnumerable<ContractDto>> GetAsync(string? status)
    {
        using var db = CreateConnection();
        return await db.QueryAsync<ContractDto>(
            "dbo.usp_GetContracts",
            new { Status = status },
            commandType: CommandType.StoredProcedure);
    }

    public async Task LogAsync(string source, string? endpoint, int? statusCode, string level, string message)
    {
        using var db = CreateConnection();
        await db.ExecuteAsync(
            "dbo.usp_LogIntegrationEvent",
            new
            {
                Source = source,
                Endpoint = endpoint,
                StatusCode = statusCode,
                Level = level,
                Message = message.Length > 2000 ? message[..2000] : message
            },
            commandType: CommandType.StoredProcedure);
    }
}
