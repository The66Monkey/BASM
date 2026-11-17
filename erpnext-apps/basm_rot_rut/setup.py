from setuptools import find_packages, setup


setup(
    name="basm_rot_rut",
    version="0.1.0",
    description="Swedish ROT/RUT claim records and Skatteverket XML export for ERPNext",
    packages=find_packages(),
    include_package_data=True,
    zip_safe=False,
)
