# Avaliação técnica do chatbot RAG

Esta pasta reúne os materiais suplementares utilizados na avaliação técnica do chatbot desenvolvido na dissertação de mestrado de **Jonas Ernesto Poli**, no Programa de Pós-Graduação em Ciência, Tecnologia e Sociedade (PPGCTS) da Universidade Federal de São Carlos (UFSCar).

O objetivo deste conjunto de arquivos é ampliar a transparência metodológica e permitir que outros pesquisadores possam inspecionar a lógica utilizada na bateria de testes, compreender os parâmetros adotados e, quando possível, implementar uma execução equivalente do experimento.

A avaliação foi realizada a partir de um fluxo específico desenvolvido no ambiente **n8n**, separado do fluxo de produção utilizado pelo chatbot no Telegram. Esse workflow executa automaticamente uma bateria controlada de perguntas, envia cada consulta individualmente à **OpenAI Responses API**, utiliza o recurso **File Search** para recuperar conteúdos do corpus da Rede Aurora e registra os resultados e metadados de cada execução em planilha.

---

## Estrutura dos arquivos

```text
avaliacao/
│
├── README.md
│
├── workflow/
│   └── bateria-testes-n8n.json
│
├── dados/
│   ├── perguntas.csv
│   ├── resultados-bateria.csv
│   └── bateria-testes-resultados.xlsx
│
└── documentacao/
    └── instrucoes-agente.md
```

### `workflow/bateria-testes-n8n.json`

Contém o workflow utilizado para executar automaticamente a bateria de testes no n8n.

O fluxo realiza, de forma sequencial:

1. leitura das perguntas previamente cadastradas;
2. seleção dos registros destinados à execução;
3. envio individual de cada pergunta à Responses API;
4. consulta ao corpus por meio do File Search;
5. coleta dos resultados de recuperação;
6. extração dos metadados técnicos da resposta;
7. registro dos resultados em planilha;
8. avanço automático para a pergunta seguinte.

A versão disponibilizada neste repositório não contém chaves de API, senhas ou credenciais de autenticação do ambiente original. Identificadores específicos da infraestrutura podem ter sido removidos ou substituídos por valores genéricos quando não são necessários para compreender a lógica do experimento.

---

## `dados/perguntas.csv`

Contém o conjunto controlado utilizado na avaliação.

A bateria foi composta por **100 perguntas**, divididas igualmente em dois grupos:

* **50 perguntas PRESENTE**, formuladas a partir de conteúdos previamente identificados nas transcrições da Rede Aurora;
* **50 perguntas AUSENTE**, formuladas sobre assuntos deliberadamente externos ao corpus.

Para as perguntas do grupo PRESENTE foi registrada previamente uma referência esperada, utilizada posteriormente para verificar se o mecanismo de recuperação encontrou o conteúdo correspondente.

As perguntas do grupo AUSENTE funcionam como controle negativo, permitindo verificar se o mecanismo de busca recupera indevidamente conteúdos do corpus para assuntos que não estão presentes na base.

---

## `dados/resultados-bateria.csv`

Contém os registros produzidos durante a bateria controlada de avaliação.

Entre os dados preservados estão:

* identificador da execução;
* ordem da pergunta;
* código do caso de teste;
* grupo da pergunta;
* pergunta enviada;
* referência esperada;
* resposta produzida pelo chatbot;
* status da chamada à API;
* duração da consulta;
* indicação de consulta ao RAG;
* presença ou ausência de resultados recuperados;
* quantidade de trechos recuperados;
* melhor score de relevância;
* arquivos associados aos resultados;
* classificação atribuída na avaliação manual;
* observações do pesquisador.

Esse arquivo corresponde aos dados utilizados no cálculo das métricas apresentadas na dissertação.

---

## `dados/bateria-testes-resultados.xlsx`

Versão preservada da planilha utilizada durante a avaliação.

O arquivo mantém a organização utilizada na análise dos dados, incluindo o conjunto de perguntas, os registros da bateria executada e a consolidação das principais métricas.

A disponibilização em formato `.xlsx` tem como objetivo preservar a estrutura original da planilha, enquanto os arquivos `.csv` permitem o acesso aos dados em um formato aberto e facilmente processável por diferentes ferramentas computacionais.

---

## `documentacao/instrucoes-agente.md`

Contém as instruções fornecidas ao modelo de linguagem durante a execução da bateria.

Essas instruções definem, entre outros aspectos, a prioridade de consulta ao corpus da Rede Aurora e o comportamento esperado quando nenhuma evidência adequada é localizada.

Quando o File Search encontra conteúdo pertinente, o agente deve construir a resposta com base nas transcrições recuperadas e indicar a fonte correspondente.

Quando o conteúdo não é encontrado no corpus, o agente deve informar explicitamente essa condição antes de utilizar o conhecimento paramétrico do modelo.

Na configuração avaliada, não foi habilitada ferramenta de busca externa na internet.

---

## Configuração da bateria avaliada

A bateria apresentada na dissertação foi executada em **7 de agosto de 2026**.

Os principais parâmetros utilizados foram:

| Parâmetro                        | Configuração                   |
| -------------------------------- | ------------------------------ |
| Orquestrador                     | n8n 1.115.3                    |
| Modelo de linguagem              | GPT-4o                         |
| API                              | OpenAI Responses API           |
| Recuperação                      | File Search                    |
| Base vetorial                    | Vector Store `Legendas-Cursos` |
| Máximo de resultados recuperados | 8                              |
| Limiar de relevância             | 0,30                           |
| Ranker                           | Automático                     |
| Armazenamento da resposta        | Habilitado                     |
| Tempo limite por chamada         | 120 segundos                   |
| Tentativas em caso de falha      | Até 3                          |
| Intervalo entre perguntas        | 0,5 segundo                    |
| Memória conversacional           | Desabilitada                   |
| Busca externa na internet        | Desabilitada                   |

Cada pergunta foi processada como uma consulta independente, sem utilização de `previous_response_id` ou de uma Conversation persistente.

---

## Resultados da execução

A bateria foi concluída com **100 respostas registradas e nenhum erro de execução**.

Na avaliação da camada de recuperação do File Search foram observados:

* 50 verdadeiros positivos (VP);
* 0 falsos negativos (FN);
* 49 verdadeiros negativos (VN);
* 1 falso positivo (FP).

A partir desses valores foram obtidas, nessa execução:

* precisão: **98,04%**;
* sensibilidade ou recall: **100%**;
* especificidade: **98%**;
* acurácia: **99%**;
* taxa de falso negativo: **0%**;
* taxa de falso positivo: **2%**.

Todas as 50 perguntas do grupo PRESENTE recuperaram a fonte esperada e foram classificadas como **RAG confirmado**.

Nas 50 perguntas do grupo AUSENTE, o chatbot informou corretamente que o conteúdo não havia sido localizado nas transcrições antes de utilizar conhecimento externo ao corpus.

O único falso positivo observado na camada bruta de recuperação ocorreu em uma pergunta de controle sobre ornitorrincos. O File Search recuperou trechos semanticamente próximos, porém inadequados, mas o chatbot não utilizou esses resultados como sustentação da resposta final.

---

## Observação sobre reprodutibilidade

Os arquivos disponibilizados neste diretório permitem reconstruir a lógica experimental e examinar os principais parâmetros utilizados na avaliação.

Entretanto, a reprodução literal das respostas não é garantida.

A bateria foi executada utilizando o identificador geral `GPT-4o`, sem fixação de um snapshot datado do modelo. Como o serviço de inferência e o mecanismo de recuperação utilizados são fornecidos por uma infraestrutura externa, alterações futuras no modelo, na API ou em outros componentes do serviço podem produzir diferenças em novas execuções.

Por essa razão, os resultados devem ser compreendidos como uma **fotografia técnica do comportamento do artefato sob a configuração utilizada na data da avaliação**, e não como garantia de que as mesmas respostas serão produzidas indefinidamente.

---

## Relação com o restante do repositório

O diretório `avaliacao/` complementa o pipeline de construção do corpus documentado neste repositório.

De forma resumida, o processo completo da pesquisa pode ser representado da seguinte maneira:

```text
Vídeos da Rede Aurora
        ↓
Extração das legendas
        ↓
Limpeza e padronização
        ↓
Estruturação em JSON
        ↓
Indexação no Vector Store
        ↓
File Search / RAG
        ↓
Chatbot
        ↓
Bateria automatizada de avaliação
        ↓
Registros e métricas
```

Dessa forma, o repositório documenta não apenas a preparação do corpus utilizado pelo chatbot, mas também parte das evidências empregadas para avaliar tecnicamente o comportamento do artefato.

---

## Autor

**Jonas Ernesto Poli**

Programa de Pós-Graduação em Ciência, Tecnologia e Sociedade — PPGCTS
Universidade Federal de São Carlos — UFSCar

Dissertação:

**O Chatbot como Mediador Sociotécnico: Inteligência Artificial e Comunicação Dialógica na Assistência Técnica e Extensão Rural (Ater)**

---

## Uso acadêmico

Os materiais disponibilizados neste diretório têm finalidade acadêmica e de pesquisa.

Caso sejam utilizados em outros trabalhos, recomenda-se citar a dissertação e o repositório correspondente.
