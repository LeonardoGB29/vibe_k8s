"""Pruebas del guardian de creditos sin AWS: se sustituye boto3 por un doble."""

import sys
import types
import unittest
from unittest import mock

sys.modules.setdefault("boto3", types.SimpleNamespace(client=None))
sys.path.insert(0, __file__.rsplit("test_handler.py", 1)[0])
import handler  # noqa: E402


class FakeClients:
    def __init__(self, credits, running=("i-1", "i-2"), dbs=None):
        self.stopped_ec2, self.stopped_rds, self.published = [], [], []
        self.credits, self.running = credits, list(running)
        # nombre -> (estado, etiquetas)
        self.dbs = dbs if dbs is not None else {
            "vibe-staging": ("available", [{"Key": "Project", "Value": "vibe"}]),
            "otro": ("available", [{"Key": "Project", "Value": "ajeno"}]),
            "vibe-parada": ("stopped", [{"Key": "Project", "Value": "vibe"}]),
        }

    def client(self, name, **_):
        return getattr(self, "_" + name)()

    def _freetier(self):
        credits = self.credits
        return types.SimpleNamespace(get_account_plan_state=lambda: credits)

    def _ec2(self):
        outer = self
        pages = [{"Reservations": [{"Instances": [{"InstanceId": i} for i in outer.running]}]}]
        return types.SimpleNamespace(
            get_paginator=lambda _: types.SimpleNamespace(paginate=lambda **kw: pages),
            stop_instances=lambda InstanceIds: outer.stopped_ec2.extend(InstanceIds),
        )

    def _rds(self):
        outer = self
        pages = [{"DBInstances": [
            {"DBInstanceIdentifier": n, "DBInstanceStatus": s, "DBInstanceArn": "arn:" + n}
            for n, (s, _) in outer.dbs.items()
        ]}]
        tags = {"arn:" + n: t for n, (_, t) in outer.dbs.items()}
        return types.SimpleNamespace(
            get_paginator=lambda _: types.SimpleNamespace(paginate=lambda **kw: pages),
            list_tags_for_resource=lambda ResourceName: {"TagList": tags[ResourceName]},
            stop_db_instance=lambda DBInstanceIdentifier: outer.stopped_rds.append(DBInstanceIdentifier),
        )

    def _sns(self):
        outer = self
        return types.SimpleNamespace(publish=lambda **kw: outer.published.append(kw))


def credits(amount):
    return {"accountPlanType": "FREE", "accountPlanRemainingCredits": {"amount": amount, "unit": "USD"}}


class CreditGuardTests(unittest.TestCase):
    def run_handler(self, fake, **env):
        env.setdefault("TOPIC_ARN", "arn:topic")
        with mock.patch.object(handler.boto3, "client", fake.client), \
                mock.patch.multiple(handler, **env):
            return handler.handler({}, None)

    def test_creditos_suficientes_no_toca_nada(self):
        fake = FakeClients(credits(80.0))
        result = self.run_handler(fake)
        self.assertEqual(result["action"], "none")
        self.assertEqual(fake.stopped_ec2 + fake.stopped_rds + fake.published, [])

    def test_bajo_el_umbral_detiene_solo_recursos_del_proyecto(self):
        fake = FakeClients(credits(19.99))
        result = self.run_handler(fake)
        self.assertEqual(result["action"], "stop")
        self.assertEqual(fake.stopped_ec2, ["i-1", "i-2"])
        self.assertEqual(fake.stopped_rds, ["vibe-staging"])  # ni la ajena ni la ya parada
        self.assertEqual(len(fake.published), 1)

    def test_justo_en_el_umbral_detiene(self):
        fake = FakeClients(credits("20.00"))
        self.assertEqual(self.run_handler(fake)["action"], "stop")

    def test_dry_run_no_detiene_pero_informa(self):
        fake = FakeClients(credits(5))
        result = self.run_handler(fake, DRY_RUN=True)
        self.assertEqual(result["ec2_stopped"], ["i-1", "i-2"])
        self.assertEqual(fake.stopped_ec2 + fake.stopped_rds, [])

    def test_sin_recursos_encendidos_no_envia_correo(self):
        fake = FakeClients(credits(5), running=(), dbs={})
        self.run_handler(fake)
        self.assertEqual(fake.published, [])

    def test_zona_de_aviso_no_detiene(self):
        fake = FakeClients(credits(35))
        result = self.run_handler(fake)
        self.assertEqual(result["action"], "warn")
        self.assertEqual(fake.stopped_ec2, [])

    def test_sin_dato_de_creditos_falla_visiblemente(self):
        fake = FakeClients({"accountPlanType": "PAID"})
        with self.assertRaises(RuntimeError):
            self.run_handler(fake)

    def test_una_rds_con_error_no_impide_parar_las_demas(self):
        fake = FakeClients(credits(1))
        original = fake._rds

        def rds_roto():
            client = original()
            real_stop = client.stop_db_instance

            def stop(DBInstanceIdentifier):
                if DBInstanceIdentifier == "vibe-staging":
                    raise RuntimeError("InvalidDBInstanceState")
                real_stop(DBInstanceIdentifier=DBInstanceIdentifier)

            client.stop_db_instance = stop
            return client

        fake._rds = rds_roto
        with self.assertRaises(RuntimeError):
            self.run_handler(fake)
        self.assertEqual(fake.stopped_ec2, ["i-1", "i-2"])  # las EC2 se pararon igualmente


if __name__ == "__main__":
    unittest.main()
