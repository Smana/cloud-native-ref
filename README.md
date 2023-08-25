# cilium-gateway-api

⚠️ **Work in progress** for a future blog post [here](https://blog.ogenki.io/)

## Dependencies matters

```mermaid
graph TD;
    Namespaces-->CRDs;
    CRDs-->Crossplane;
    Crossplane-->Infrastructure;
    Infrastructure-->Apps;
    Security-->Apps;
```
