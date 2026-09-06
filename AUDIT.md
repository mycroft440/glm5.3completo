# Auditoria técnica — GLM-5.3 completo

Última rodada: 2026-09-06. Revisão feita procurando pontos que poderiam falhar na primeira implantação MI300X Spot ou reintroduzir regressões no H200.

## Achados desta rodada e correções

1. **Pin do modelo estava preso a um chat template anterior.** Atualizado para `aca966e4e02791568aa6a4ced368624b3d897f42`, commit oficial que corrige `chat_template.jinja` para tool-result reordering e conteúdo `None`.
2. **Reinstalar sobrescrevia tuning.** O perfil agora preserva contexto, sequências, utilização, batch e KV dtype no mesmo acelerador; defaults só voltam quando os valores estão `auto`/vazios ou quando o perfil muda.
3. **Os três comandos do README podiam falhar por disco.** O projeto agora torna explícito o Managed Disk >=2 TiB e o preflight falha antes de baixar pesos se o cache compartilhar o root filesystem.
4. **NVMe local Spot podia ser confundido com armazenamento útil.** O preflight rejeita `/dev/disk/azure/resource`, `/dev/disk/azure/local/...` e `Microsoft NVMe Direct Disk` por default.
5. **Topologia ROCm era apenas consultada.** Agora as 8 GPUs precisam expor `xgmi_hive_id`, pertencer ao mesmo hive e a topologia precisa reportar XGMI.
6. **CI não construía realmente a imagem ROCm.** Em push para `main`, passa a fazer build real de `Dockerfile.rocm` e importar `torch`, `vllm` e `aiter` dentro da imagem.
7. **Responses API não era exercitada.** `glm-manage test` agora chama `/v1/responses` e exige `RESPONSES_OK` sem `<think>`.
8. **Spot era só documentação.** Novo `glm53-spot-watch.service` consulta Azure Scheduled Events e reage a `Preempt` fechando gateway/runtime e registrando o evento no storage persistente.
9. **Timeout inicial era curto para o primeiro carregamento.** Novas instalações usam 14.400 s (4 h).

## Riscos que continuam dependentes de hardware real

- build/start completo do runtime ROCm com 8× MI300X;
- carregamento integral do checkpoint;
- AITER e MTP sob carga;
- 524k de contexto com headroom real;
- XGMI/Infinity Fabric sob tráfego sustentado;
- comportamento real do Scheduled Events em eviction Spot;
- reboot/deallocate e reaproveitamento do Managed Disk;
- throughput/latência/concorrência;
- H200: risco upstream FlashMLA/sparse-decode do vLLM 0.28.0 continua mitigado, não eliminado.

## Critério de aprovação

CI verde é requisito para testar a VM, não evidência de produção. Produção só deve ser declarada depois de `glm-manage test`, stress, reboot e cenário Spot real passarem no hardware alvo.
