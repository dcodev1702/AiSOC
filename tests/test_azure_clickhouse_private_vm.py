"""Security contract for the Azure ClickHouse/Neo4j PoC host.

The VM needs outbound access for Ubuntu packages and container images, but an
address attached to its NIC also gives the host an Internet-routable endpoint.
Outbound egress belongs on the subnet NAT gateway; the workload NIC must carry
only its private address.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLICKHOUSE_TF = ROOT / "infra" / "terraform" / "azure" / "clickhouse.tf"


def _resource_block(source: str, resource_type: str, name: str) -> str:
    marker = f'resource "{resource_type}" "{name}"'
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise AssertionError(f"unterminated Terraform block: {marker}")


def test_clickhouse_vm_has_no_nic_bound_public_ip() -> None:
    source = CLICKHOUSE_TF.read_text()
    nic = _resource_block(source, "azurerm_network_interface", "clickhouse")

    assert "public_ip_address_id" not in nic


def test_clickhouse_subnet_owns_outbound_nat() -> None:
    source = CLICKHOUSE_TF.read_text()
    nat = _resource_block(source, "azurerm_nat_gateway", "clickhouse")
    public_ip = _resource_block(source, "azurerm_nat_gateway_public_ip_association", "clickhouse")
    subnet = _resource_block(source, "azurerm_subnet_nat_gateway_association", "clickhouse")
    nic = _resource_block(source, "azurerm_network_interface", "clickhouse")

    assert 'sku_name                = "Standard"' in nat
    assert "azurerm_public_ip.clickhouse_outbound.id" in public_ip
    assert "azurerm_nat_gateway.clickhouse.id" in public_ip
    assert "azurerm_subnet.clickhouse.id" in subnet
    assert "azurerm_nat_gateway.clickhouse.id" in subnet
    assert "azurerm_subnet_nat_gateway_association.clickhouse" in nic
