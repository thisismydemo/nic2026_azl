# Hybrid Cloud: Plan, Deploy, and Operate Azure Local from Discovery to Day 2

## Session Overview

**Conference:** NIC 2026  
**Date:** October 15, 2026  
**Time:** 9:50 AM (W Europe Time)  
**Duration:** 60 minutes  
**Level:** 400 (Expert)  
**Location:** Amsterdam

The entire Azure Local lifecycle delivered in one hour: from initial planning and workload discovery, through cloud-driven deployment and Day-2 readiness, to ongoing Day-2 operations. This fast-paced, demo-driven session walks through a real engagement flow with every artifact available for reproduction afterward.

**No prerequisites beyond curiosity.** Familiarity with Hyper-V, Failover Clustering, VMware, or basic Azure concepts will enhance your learning, but not required.

## What You'll Learn

A comprehensive walkthrough of the complete Azure Local lifecycle, organized into three phases:

### Phase 1: Plan and Discover
- **Workload Assessment** - Using Azure Migrate for accurate discovery
- **Sizing** - Hardware requirements against Azure Local 2604 specifications
- **Hardware Decision Framework** - Validated solutions, Premier partnerships, or disaggregated SAN-attached architectures
- **Topology Selection** - Cluster patterns including Rack Aware Cluster configurations
- **Network Design** - Network ATC intent-based design
- **Identity Strategy** - Local Identity with Key Vault, Active Directory, or hybrid approaches

### Phase 2: Deploy and Day-2 Ready
- **Cloud-Driven Deployment** - Infrastructure-as-code through portal and Bicep
- **Local Identity Bootstrap** - Secure initialization without on-premises dependencies
- **Network ATC Application** - Automated network intent implementation
- **Post-Deployment Validation** - Verification procedures
- **Day-2 Readiness** - Azure Monitor, Update Manager, Backup, RBAC with PIM, Azure Policy

### Phase 3: Day 2 Operations
- **Lifecycle Manager** - Solution updates with validation
- **Fault Diagnosis** - Node failures, drive failures, Network ATC drift resolution
- **Capacity Management** - Utilization monitoring and expansion planning
- **VM Lifecycle** - Managing virtual machines through Arc
- **Disaster Recovery** - Planned ASR failover to Azure

## Live Demo

A complete walkthrough showing discovery → deployment → Day-2 readiness → operations → disaster recovery, with every step demonstrating real-world scenarios.

## Attendee Deliverables

You leave with production-configurable artifacts:

- ✅ **Bicep Deployment Package** - Complete infrastructure-as-code for cluster and VM deployment
- ✅ **Azure Policy Initiative** - Compliance baseline for hybrid cloud
- ✅ **Day-2 Operations Runbook** - Step-by-step operational procedures
- ✅ **Azure Update Manager Templates** - Maintenance configuration patterns
- ✅ **Azure Monitor Data Collection Rules** - Cost-conscious telemetry
- ✅ **Alert Rules** - Pre-built monitoring and alerting
- ✅ **Complete GitHub Repository** - Full deployment code, runbooks, and documentation

## Repository Contents

### `/PRESENTATION`
- NIC 2026 PowerPoint presentation (using official NIC template)
- Speaker notes and slide references

### `/HANDOUTS`
- **Azure_Local_Sizing_Guide.md** - Hardware selection and capacity planning
- **Network_ATC_Design.md** - Network intent design patterns
- **Day2_Operations_Runbook.md** - Complete operations procedures
- **ASR_Failover_Procedures.md** - Disaster recovery and failover steps
- **Troubleshooting_Guide.md** - Common issues and resolutions

### `/src/bicep`
- `azure-local-cluster.bicep` - Cluster infrastructure
- `vm-deployment.bicep` - Virtual machine deployment
- `network-atc.bicep` - Network ATC intent configuration
- `monitoring-stack.bicep` - Monitoring and telemetry setup

### `/src/scripts`
- **discovery/** - Assess-Workloads.ps1
- **deploy/** - Local-Identity-Bootstrap.ps1, Post-Deploy-Validation.ps1
- **operations/** - Fault-Diagnosis.ps1, Capacity-Check.ps1, Update-Manager-Config.ps1
- **asr/** - Failover-Procedures.ps1

### `/src/policies`
- `hybrid-baseline-initiative.json` - Azure Policy initiative

### `/src/azure-monitor`
- `dcr-hybrid.json` - Data Collection Rules
- `alert-rules.json` - Alert rule templates

### `/src/runbooks`
- `Day2-Operations-Runbook.md` - Detailed operational procedures

## Getting Started

1. **Read the Sizing Guide** - Start with `HANDOUTS/Azure_Local_Sizing_Guide.md`
2. **Review Network Design** - Check `HANDOUTS/Network_ATC_Design.md`
3. **Plan Your Deployment** - Use Bicep templates in `/src/bicep`
4. **Deploy** - Run Bicep deployment with Post-Deploy-Validation.ps1
5. **Operate** - Follow Day2-Operations-Runbook.md

## Prerequisites

- Basic understanding of Azure concepts
- Familiarity with Hyper-V, Failover Clustering, or virtualization platforms (helpful)
- PowerShell 7+ for scripting
- Access to Azure subscription and Azure Local cluster

## Support & Questions

For questions about the content:
- Review the Troubleshooting Guide in HANDOUTS
- Check the Day-2 Operations Runbook for operational questions
- Refer to official Microsoft Azure Local documentation

## License

These materials are provided as-is for educational purposes.

## Speaker

Presented at NIC 2026

---

**Questions? Issues? Feedback?** Open an issue in this repository.
