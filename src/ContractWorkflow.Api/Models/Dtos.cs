namespace ContractWorkflow.Api.Models;

public record CreateContractRequest(
    string Title,
    string Counterparty,
    string ContractType,
    decimal? ContractValue,
    int? SharePointItemId,
    string SubmittedBy);

public record DecisionRequest(string Decision, string ActedBy, string? Comments);

public class CreateResult
{
    public int ContractId { get; set; }
    public string Status { get; set; } = "";
    public bool AlreadyExisted { get; set; }
}

public class ContractDto
{
    public int ContractId { get; set; }
    public string Title { get; set; } = "";
    public string Counterparty { get; set; } = "";
    public string ContractType { get; set; } = "";
    public decimal? ContractValue { get; set; }
    public string Status { get; set; } = "";
    public int? SharePointItemId { get; set; }
    public string SubmittedBy { get; set; } = "";
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}
