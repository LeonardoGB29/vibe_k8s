"""Guardian de creditos: pausa las EC2 y RDS del proyecto cuando el saldo baja de un umbral.

Lee el saldo real del plan (freetier:GetAccountPlanState), no una estimacion de
gasto. Se ejecuta cada hora desde EventBridge. Solo toca recursos con la etiqueta
Project=<PROJECT_TAG>. No puede detener el balanceador (ELB), que sigue cobrando
~0,6 USD/dia; para eso hay que ejecutar `terraform destroy`.
"""

import datetime
import json
import logging
import os

import boto3

log = logging.getLogger()
log.setLevel(logging.INFO)

PROJECT_TAG = os.environ.get("PROJECT_TAG", "vibe")
STOP_BELOW_USD = float(os.environ.get("STOP_BELOW_USD", "20"))
WARN_BELOW_USD = float(os.environ.get("WARN_BELOW_USD", "50"))
WARN_HOUR_UTC = int(os.environ.get("WARN_HOUR_UTC", "12"))
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
TOPIC_ARN = os.environ.get("TOPIC_ARN", "")


def remaining_credits():
    """Devuelve (creditos_restantes_usd, tipo_de_plan)."""
    # El endpoint de Free Tier es global y vive en us-east-1.
    state = boto3.client("freetier", region_name="us-east-1").get_account_plan_state()
    credits = state.get("accountPlanRemainingCredits")
    if not credits or "amount" not in credits:
        raise RuntimeError("La cuenta no informa creditos restantes: %s" % json.dumps(state, default=str))
    return float(credits["amount"]), state.get("accountPlanType", "desconocido")


def stop_ec2_instances():
    ec2 = boto3.client("ec2")
    filters = [
        {"Name": "tag:Project", "Values": [PROJECT_TAG]},
        {"Name": "instance-state-name", "Values": ["pending", "running"]},
    ]
    ids = []
    for page in ec2.get_paginator("describe_instances").paginate(Filters=filters):
        for reservation in page["Reservations"]:
            ids.extend(i["InstanceId"] for i in reservation["Instances"])
    if ids and not DRY_RUN:
        ec2.stop_instances(InstanceIds=ids)
    return ids


def stop_rds_instances():
    """Detiene las RDS etiquetadas. Devuelve (detenidas, errores)."""
    rds = boto3.client("rds")
    stopped, errors = [], []
    for page in rds.get_paginator("describe_db_instances").paginate():
        for db in page["DBInstances"]:
            if db["DBInstanceStatus"] != "available":
                continue
            name = db["DBInstanceIdentifier"]
            try:
                tags = rds.list_tags_for_resource(ResourceName=db["DBInstanceArn"])["TagList"]
                if not any(t["Key"] == "Project" and t["Value"] == PROJECT_TAG for t in tags):
                    continue
                if not DRY_RUN:
                    rds.stop_db_instance(DBInstanceIdentifier=name)
                stopped.append(name)
            except Exception as exc:  # una RDS con error no debe impedir parar las demas
                log.error("No pude detener %s: %s", name, exc)
                errors.append("%s: %s" % (name, exc))
    return stopped, errors


def notify(subject, message):
    log.info("%s | %s", subject, message)
    if TOPIC_ARN:
        boto3.client("sns").publish(TopicArn=TOPIC_ARN, Subject=subject[:100], Message=message)


def handler(event, context):
    remaining, plan = remaining_credits()
    result = {"remaining_usd": remaining, "plan": plan, "stop_below_usd": STOP_BELOW_USD, "dry_run": DRY_RUN}

    if remaining <= STOP_BELOW_USD:
        ec2_ids = stop_ec2_instances()
        rds_ids, rds_errors = stop_rds_instances()
        result.update(action="stop", ec2_stopped=ec2_ids, rds_stopped=rds_ids, errors=rds_errors)
        if ec2_ids or rds_ids or rds_errors:
            notify(
                "VIBE: creditos AWS bajos, recursos pausados",
                "Quedan %.2f USD (umbral %.2f). %s EC2 y RDS detenidas: %s. "
                "El ELB sigue cobrando: ejecuta terraform destroy si no vas a usarlo. Errores: %s"
                % (remaining, STOP_BELOW_USD, "(simulacion)" if DRY_RUN else "",
                   ec2_ids + rds_ids or "ninguna", rds_errors or "ninguno"),
            )
    elif remaining <= WARN_BELOW_USD:
        result["action"] = "warn"
        # Un solo aviso al dia para no llenar el correo cada hora.
        if datetime.datetime.now(datetime.timezone.utc).hour == WARN_HOUR_UTC:
            notify(
                "VIBE: quedan pocos creditos AWS",
                "Quedan %.2f USD. Se pausaran las EC2 y RDS al llegar a %.2f USD." % (remaining, STOP_BELOW_USD),
            )
    else:
        result["action"] = "none"

    log.info(json.dumps(result))
    if result.get("errors"):
        raise RuntimeError("Fallo parcial al detener recursos: %s" % result["errors"])
    return result
